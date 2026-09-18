import Foundation
import Speech

/// Transcribes with Apple's `Speech` framework, pinned to on-device recognition. This is
/// the "built-in tool" option: it ships with iOS, so it adds nothing to the app download,
/// costs nothing per episode, and the audio never leaves the phone.
struct AppleSpeechTranscriber: SpeechTranscribing {
    let kind: TranscriptionEngineKind = .onDevice

    /// How long a window may go without a single sign of life before it's called stuck.
    /// The recognizer reports neither a result nor an error in that case, so the loop
    /// needs its own way out — but measured from the last revision rather than from the
    /// start, or a long window that is working perfectly well gets cut off at the same
    /// mark, and an app that was put away comes back to a window already declared dead.
    private static let silenceTimeoutSeconds: TimeInterval = 60

    /// How long to let a freshly built recognizer settle before believing its flags.
    private static let availabilitySeconds: TimeInterval = 5

    /// The recognizer revises its hypothesis several times a second, and each revision
    /// rewrites the whole tail. Published at that rate the text reads as a flicker rather
    /// than as words arriving, so revisions are shown at a pace a person can actually read.
    private static let partialInterval: TimeInterval = 1.0

    static var isSupported: Bool {
        SFSpeechRecognizer(locale: preferredLocale)?.supportsOnDeviceRecognition ?? false
    }

    /// Every locale the framework has a recognizer for, for the language picker.
    static var supportedLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted {
            $0.identifier(.bcp47).localizedCompare($1.identifier(.bcp47)) == .orderedAscending
        }
    }

    /// Resolves what the listener asked for against what the framework actually has.
    ///
    /// `Locale.current.identifier` is ICU-style (`zh_Hans_CN`) while `supportedLocales()`
    /// hands back BCP-47 (`zh-Hans-CN`), so comparing the two as strings never matched.
    /// Match on the language itself — same region first — and only fall back to en-US when
    /// the language isn't supported at all.
    static func resolvedLocale(_ requested: String?) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let wanted = requested.map(Locale.init(identifier:)) ?? Locale.current
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) {
            return exact
        }
        let sameLanguage = supported.filter { $0.language.languageCode == wanted.language.languageCode }
        return sameLanguage.first { $0.region == wanted.region } ?? sameLanguage.first ?? Locale(identifier: "en-US")
    }

    /// What to use when the listener hasn't picked a language for this episode yet.
    static var preferredLocale: Locale { resolvedLocale(nil) }

    func transcribe(
        audioURL: URL,
        startOffset: Double,
        context: TranscriptionContext,
        onPartial: @escaping @Sendable (TranscriptDraft) -> Void
    ) async throws -> [TranscriptSegment] {
        try await Self.authorize()
        let locale = Self.resolvedLocale(context.localeIdentifier)
        let localeName = locale.identifier(.bcp47)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.onDeviceUnavailable(locale: localeName)
        }
        // `supportsOnDeviceRecognition` is the flag that matters here, and it's the only one
        // read: `isAvailable` tracks Apple's *server* path and reads false with no network
        // even when the local model is installed and would work fine — gating on it would
        // break the offline case this engine exists for.
        //
        // And it's read, not obeyed. The flag is a false negative often enough — phones
        // with the language's dictation model plainly installed still report false — that
        // refusing on it alone means refusing to transcribe audio this phone can handle.
        // So try regardless, and only blame the missing model if the attempt also fails.
        let hasLocalModel = await Self.becomesTrue(recognizer, \.supportsOnDeviceRecognition)

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        // The recognizer re-reads the whole window each time it revises, so partials are
        // the finished lines plus a rough tail. Waiting for `isFinal` instead meant a
        // minute of blank screen per window, which read as "nothing is happening".
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = context.phrases

        do {
            let segments = try await Self.recognize(
                recognizer: recognizer, request: request, startOffset: startOffset, engine: kind.rawValue,
                onPartial: onPartial
            )
            withExtendedLifetime(recognizer) {}
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            withExtendedLifetime(recognizer) {}
            throw hasLocalModel ? error : TranscriptionError.onDeviceModelMissing(locale: localeName)
        }
    }

    /// A freshly built recognizer reads back `false` for a moment — the framework settles
    /// these flags asynchronously, through its delegate. Bailing on the first read made
    /// on-device transcription fail whenever it was the first thing tried after launch, so
    /// give the flag a moment to come up before believing it.
    private static func becomesTrue(_ recognizer: SFSpeechRecognizer, _ flag: KeyPath<SFSpeechRecognizer, Bool>) async -> Bool {
        let deadline = Date().addingTimeInterval(availabilitySeconds)
        while !recognizer[keyPath: flag] && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return recognizer[keyPath: flag]
    }

    private static func authorize() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .denied, .restricted: throw TranscriptionError.notAuthorized
        default: break
        }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
    }

    /// Lines are built inside the callback so nothing but plain values crosses back out.
    private static func recognize(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest,
        startOffset: Double,
        engine: String,
        onPartial: @escaping @Sendable (TranscriptDraft) -> Void
    ) async throws -> [TranscriptSegment] {
        let gate = RecognitionGate()
        let pace = PartialPace(minimumInterval: partialInterval)
        let heard = HeardWords()
        let watchdog = Watchdog(timeout: silenceTimeoutSeconds) {
            gate.finish(.failure(TranscriptionError.requestFailed))
        }
        defer { watchdog.stop() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.attach(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    watchdog.touch()
                    if let error {
                        gate.finish(.failure(error))
                        return
                    }
                    guard let result else { return }
                    // Partials go through `split`, which copes with the missing word
                    // timings they almost always carry; the final result has real ones.
                    let words = Self.words(in: result.bestTranscription)
                    // Every hypothesis is folded in, not just the last: the recognizer
                    // restarts at utterance boundaries, so the final result can describe
                    // only the tail end of the window.
                    let sofar = heard.absorb(words)
                    if result.isFinal {
                        gate.finish(.success(
                            TranscriptLines.grouped(
                                sofar.isEmpty ? words : sofar, startOffset: startOffset, engine: engine
                            )
                        ))
                    } else if pace.allows() {
                        onPartial(TranscriptLines.split(words, startOffset: startOffset, engine: engine))
                    }
                }
                gate.attach(task: task)
            }
        } onCancel: {
            // The listener jumped elsewhere in the episode: this window is no longer the
            // one worth spending on, and nothing here gets saved.
            gate.cancel()
        }
    }

    /// Apple hands back individual words; the grouping itself lives in `TranscriptLines`
    /// so it can be tested (and ported) without the `Speech` framework.
    static func lines(
        from transcription: SFTranscription,
        startOffset: Double,
        engine: String,
        maxLineSeconds: Double = 12,
        pauseSeconds: Double = 0.7
    ) -> [TranscriptSegment] {
        TranscriptLines.grouped(
            words(in: transcription), startOffset: startOffset, engine: engine,
            maxLineSeconds: maxLineSeconds, pauseSeconds: pauseSeconds
        )
    }

    static func words(in transcription: SFTranscription) -> [RecognizedWord] {
        transcription.segments.map {
            RecognizedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
        }
    }
}

/// Recognition can report a result, a timeout and a cancellation at once, and a checked
/// continuation resumed twice traps. This also owns cancelling the underlying recognition
/// task, which otherwise keeps chewing on a window nobody is waiting for any more.
private final class RecognitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    /// A result that landed before the continuation was attached.
    private var pending: Result<[TranscriptSegment], Error>?
    private var isDone = false

    func attach(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        lock.lock()
        if let pending {
            isDone = true
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Cancellation can arrive before the recognition task exists, so a gate that's
    /// already finished cancels the task the moment it shows up.
    func attach(task: SFSpeechRecognitionTask) {
        lock.lock()
        let finished = isDone
        self.task = task
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ result: Result<[TranscriptSegment], Error>) {
        lock.lock()
        guard !isDone else { return lock.unlock() }
        guard let continuation else {
            pending = result
            return lock.unlock()
        }
        isDone = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}

/// Ends a window that has gone quiet. Every revision resets it, so it measures silence
/// rather than elapsed time: a long window that's still producing is left alone, and one
/// that stopped — the usual cause being the app suspended out from under the recognizer —
/// gives up in a minute instead of hanging the pass.
private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let onTimeout: @Sendable () -> Void
    private var lastActivity = Date()
    private var isStopped = false

    init(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
        schedule()
    }

    func touch() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }

    private func schedule() {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout / 4) { [weak self] in
            guard let self else { return }
            lock.lock()
            let stopped = isStopped
            let quietFor = Date().timeIntervalSince(lastActivity)
            lock.unlock()
            guard !stopped else { return }
            guard quietFor < timeout else { return onTimeout() }
            schedule()
        }
    }
}

/// Rate-limits the recognizer's revisions on the way out. Not on the main actor: partials
/// arrive on the framework's own queue, and the point is to drop them before they get
/// anywhere near the view.
private final class PartialPace: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastSent = Date.distantPast

    init(minimumInterval: TimeInterval) { self.minimumInterval = minimumInterval }

    func allows() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= minimumInterval else { return false }
        lastSent = now
        return true
    }
}

/// Everything the recognizer has said about the window it's working on, in one place.
/// Lives here rather than in the callback because that callback is handed a new hypothesis
/// each time and has no memory of the last one.
private final class HeardWords: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [RecognizedWord] = []

    func absorb(_ incoming: [RecognizedWord]) -> [RecognizedWord] {
        lock.lock()
        defer { lock.unlock() }
        words = TranscriptLines.absorbing(incoming, into: words)
        return words
    }
}
