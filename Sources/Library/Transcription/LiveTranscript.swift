import Foundation

/// Owns the transcript of whatever's playing: what's already stored, what's being filled
/// in right now, and the user's corrections.
///
/// The loop is gap-driven rather than file-driven. Everything already transcribed —
/// including a half-finished episode from a previous session — is left alone, and only the
/// uncovered stretches are sent out, nearest the playhead first, so listening from the
/// middle starts producing text immediately. Every window is saved as it lands, so
/// quitting mid-episode keeps what got done.
@MainActor
final class LiveTranscript: ObservableObject {
    static let shared = LiveTranscript()

    @Published private(set) var track: Track?
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var edits: [TranscriptEdit] = []
    @Published private(set) var activeWindow: TimeWindow?
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var duration: Double = 0

    @Published var engineKind: TranscriptionEngineKind {
        didSet {
            UserDefaults.standard.set(engineKind.rawValue, forKey: Self.engineDefaultsKey)
            guard engineKind != oldValue else { return }
            restart()
        }
    }

    /// Off by default: transcribing sends audio somewhere (or spends battery), so it's the
    /// listener's call, not something that starts happening on its own.
    @Published var isLiveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isLiveEnabled, forKey: Self.liveDefaultsKey)
            guard isLiveEnabled != oldValue else { return }
            isLiveEnabled ? restart() : stop()
        }
    }

    private static let engineDefaultsKey = "transcript.engine"
    private static let liveDefaultsKey = "transcript.live"

    private let transcriptStore = TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private var fillTask: Task<Void, Never>?
    /// Bumped on every stop/start so a cancelled pass can't clear the state of the one
    /// that replaced it.
    private var fillGeneration = 0

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.engineDefaultsKey) ?? ""
        engineKind = TranscriptionEngineKind(rawValue: stored) ?? .onDevice
        isLiveEnabled = UserDefaults.standard.bool(forKey: Self.liveDefaultsKey)
    }

    // MARK: Display

    /// Silent stretches are stored as empty lines — they're how "this part has been
    /// listened to, there was nothing said" is remembered — but they're not shown.
    var lines: [TranscriptSegment] { segments.filter { !$0.text.isEmpty } }

    func currentLine(at time: Double) -> TranscriptSegment? {
        lines.last { $0.start <= time }
    }

    var coverageFraction: Double {
        guard duration > 0 else { return segments.isEmpty ? 0 : 1 }
        return min(1, TranscriptCoverage.coveredSeconds(segments) / duration)
    }

    var isComplete: Bool {
        duration > 0 && TranscriptCoverage.gaps(in: segments, duration: duration).isEmpty
    }

    // MARK: Lifecycle

    func attach(track newTrack: Track?) {
        guard track?.id != newTrack?.id else { return }
        stop()
        track = newTrack
        segments = []
        edits = []
        lastError = nil
        duration = newTrack?.durationMs.map { Double($0) / 1000 } ?? 0
        guard let newTrack else { return }
        segments = (try? transcriptStore.find(trackID: newTrack.id)) ?? []
        edits = (try? transcriptStore.edits(trackID: newTrack.id)) ?? []
        if isLiveEnabled { start() }
    }

    func start() {
        guard fillTask == nil, let track else { return }
        lastError = nil
        fillGeneration += 1
        let generation = fillGeneration
        fillTask = Task { [weak self] in
            await self?.fillGaps(track: track)
            guard let self, generation == fillGeneration else { return }
            fillTask = nil
            isWorking = false
            activeWindow = nil
        }
    }

    func stop() {
        fillGeneration += 1
        fillTask?.cancel()
        fillTask = nil
        isWorking = false
        activeWindow = nil
    }

    private func restart() {
        stop()
        if isLiveEnabled { start() }
    }

    /// Throws away the stored transcript and transcribes the episode again from scratch.
    /// Corrections are kept — both as history and as vocabulary for the new pass.
    func forceReload() {
        guard let track else { return }
        stop()
        try? transcriptStore.delete(trackID: track.id)
        segments = []
        lastError = nil
        isLiveEnabled = true
        start()
    }

    // MARK: Editing

    func applyEdit(to segment: TranscriptSegment, newText: String) {
        guard let track else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        segments = (try? transcriptStore.applyEdit(trackID: track.id, segmentStart: segment.start, newText: trimmed)) ?? segments
        edits = (try? transcriptStore.edits(trackID: track.id)) ?? edits
    }

    // MARK: Filling

    private func fillGaps(track: Track) async {
        guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else {
            lastError = "No storage provider configured for this episode."
            return
        }

        isWorking = true
        let localURL: URL
        do {
            localURL = try await AudioWindowFile.localURL(track: track, provider: provider)
        } catch {
            lastError = "Couldn't read the audio: \(error.localizedDescription)"
            return
        }
        if duration <= 0 { duration = await AudioWindowFile.duration(of: localURL) }
        guard duration > 0 else {
            lastError = "Couldn't work out how long this episode is."
            return
        }

        let transcriber = engineKind.transcriber
        let context = transcriptionContext()

        while !Task.isCancelled {
            let windows = TranscriptCoverage.windows(
                in: segments,
                duration: duration,
                windowSeconds: engineKind.windowSeconds,
                from: PlaybackEngine.shared.currentTime
            )
            guard let window = windows.first else { break }
            activeWindow = window
            do {
                let produced = try await transcribe(
                    window: window, of: localURL, using: transcriber, context: context
                )
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                segments = (try? transcriptStore.merge(
                    trackID: track.id, incoming: produced, engine: engineKind.rawValue
                )) ?? TranscriptStore.merging(existing: segments, incoming: produced)
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func transcribe(
        window: TimeWindow, of localURL: URL, using transcriber: any SpeechTranscribing, context: TranscriptionContext
    ) async throws -> [TranscriptSegment] {
        let wholeFile = window.start <= 0.01 && window.end >= duration - 0.01
        let audioURL = wholeFile ? localURL : try await AudioWindowFile.slice(of: localURL, window: window)
        defer { if !wholeFile { try? FileManager.default.removeItem(at: audioURL) } }

        let lines = try await transcriber.transcribe(
            audioURL: audioURL, startOffset: window.start, context: context
        )
        return Self.padded(lines, toCover: window, engine: transcriber.kind.rawValue)
    }

    /// Whatever the recognizer didn't speak for — leading silence, a trailing music bed,
    /// the whole window if nobody talks — is recorded as an empty line. Without it that
    /// stretch stays a "gap" and gets sent out again on every pass, forever.
    static func padded(_ lines: [TranscriptSegment], toCover window: TimeWindow, engine: String) -> [TranscriptSegment] {
        var produced = lines
        if let first = lines.first, first.start - window.start >= 0.5 {
            produced.append(TranscriptSegment(start: window.start, end: first.start, text: "", engine: engine))
        }
        let lastEnd = max(lines.map(\.end).max() ?? window.start, window.start)
        if window.end - lastEnd >= 0.5 {
            produced.append(TranscriptSegment(start: lastEnd, end: window.end, text: "", engine: engine))
        }
        return produced
    }

    /// This episode's corrections first, then anything recently fixed elsewhere — the same
    /// misheard name usually shows up across a whole show.
    private func transcriptionContext() -> TranscriptionContext {
        let recent = (try? transcriptStore.recentEdits()) ?? []
        let ids = Set(edits.map(\.id))
        return TranscriptionContext.from(edits: edits + recent.filter { !ids.contains($0.id) })
    }
}
