import Foundation
import Speech

/// Transcribes with Apple's `Speech` framework, pinned to on-device recognition. This is
/// the "built-in tool" option: it ships with iOS, so it adds nothing to the app download,
/// costs nothing per episode, and the audio never leaves the phone.
struct AppleSpeechTranscriber: SpeechTranscribing {
    let kind: TranscriptionEngineKind = .onDevice

    /// A window that hasn't come back by now is stuck — the recognizer reports neither a
    /// result nor an error in that case, so the live loop needs its own way out.
    private static let timeoutSeconds: TimeInterval = 180

    static var isSupported: Bool {
        SFSpeechRecognizer(locale: preferredLocale)?.supportsOnDeviceRecognition ?? false
    }

    private static var preferredLocale: Locale {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        return supported.contains(Locale.current.identifier) ? Locale.current : Locale(identifier: "en-US")
    }

    func transcribe(audioURL: URL, startOffset: Double, context: TranscriptionContext) async throws -> [TranscriptSegment] {
        try await Self.authorize()
        guard let recognizer = SFSpeechRecognizer(locale: Self.preferredLocale), recognizer.isAvailable else {
            throw TranscriptionError.onDeviceUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = context.phrases

        let segments = try await Self.recognize(
            recognizer: recognizer, request: request, startOffset: startOffset, engine: kind.rawValue
        )
        withExtendedLifetime(recognizer) {}
        return segments
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
        engine: String
    ) async throws -> [TranscriptSegment] {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.finish { continuation.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let lines = Self.lines(from: result.bestTranscription, startOffset: startOffset, engine: engine)
                gate.finish { continuation.resume(returning: lines) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                gate.finish { continuation.resume(throwing: TranscriptionError.requestFailed) }
            }
        }
    }

    /// Apple hands back individual words, not sentences. Lyric-style highlighting needs
    /// lines, so words are grouped until a sentence ends, the speaker pauses, or the line
    /// simply gets too long to highlight as one unit.
    static func lines(
        from transcription: SFTranscription,
        startOffset: Double,
        engine: String,
        maxLineSeconds: Double = 12,
        pauseSeconds: Double = 0.7
    ) -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        var words: [String] = []
        var lineStart: Double = 0
        var lineEnd: Double = 0

        func flush() {
            let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { words = []; return }
            lines.append(TranscriptSegment(
                start: startOffset + lineStart, end: startOffset + max(lineEnd, lineStart), text: text, engine: engine
            ))
            words = []
        }

        for (index, word) in transcription.segments.enumerated() {
            if words.isEmpty { lineStart = word.timestamp }
            words.append(word.substring)
            lineEnd = word.timestamp + word.duration

            let next = index + 1 < transcription.segments.count ? transcription.segments[index + 1] : nil
            let endsSentence = word.substring.last.map { ".!?。！？".contains($0) } ?? false
            let pausesAfter = next.map { $0.timestamp - lineEnd >= pauseSeconds } ?? true
            let tooLong = lineEnd - lineStart >= maxLineSeconds
            if endsSentence || pausesAfter || tooLong || next == nil { flush() }
        }
        flush()
        return lines
    }
}

/// Recognition can report a result and a timeout at once; a checked continuation resumed
/// twice traps.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var isDone = false

    func finish(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isDone else { return }
        isDone = true
        body()
    }
}
