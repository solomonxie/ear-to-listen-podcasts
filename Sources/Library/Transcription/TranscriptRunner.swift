import Foundation

/// Owns the transcript of whatever's playing: what's stored, the corrections made to it,
/// and whichever whole-episode pass is running right now.
///
/// One pass, front to back, in the background. It used to transcribe live — chasing the
/// playhead, publishing half-made lines, re-running a window whenever you seeked — which
/// made text appear sooner and everything else worse: lines rewrote themselves under the
/// reader, the page flickered, and the same audio was recognised several times over. A
/// pass now runs whole and out of sight, reports a percentage, and puts the whole
/// transcript up at once when it's done.
///
/// Nothing on disk changes until a pass finishes. Pressing a recogniser's button while an
/// episode already has a transcript is safe: the old one stays whole and readable until
/// the new one is ready to replace it. The tradeoff is deliberate — a pass abandoned
/// halfway (cancelled, failed, app killed) is thrown away rather than half-applied.
@MainActor
final class TranscriptRunner: ObservableObject {
    static let shared = TranscriptRunner()

    @Published private(set) var track: Track?
    @Published private(set) var segments: [TranscriptSegment] = [] {
        didSet { rebuildLines() }
    }
    @Published private(set) var edits: [TranscriptEdit] = []
    /// Which recogniser is running, or nil when nothing is. Doubles as the button's state:
    /// pressing the one that's running stops it.
    @Published private(set) var runningEngine: TranscriptionEngineKind?
    /// How much of the episode this pass has got through, 0…1. The only thing shown while
    /// it runs — there is nothing else worth saying, and a moving wall of half-made text
    /// was worse than nothing.
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var duration: Double = 0

    /// What language the audio is in. Nil means "whatever the phone is set to", which is
    /// a guess about the listener rather than about the recording — see `inheritedLanguage`.
    @Published var localeIdentifier: String? {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: Self.localeDefaultsKey) }
    }

    /// The answer to "every episode, or only the ones I ask for?", set once in Settings.
    /// With it on, opening an episode with no transcript starts an on-device pass.
    @Published var startsAutomatically: Bool {
        didSet { UserDefaults.standard.set(startsAutomatically, forKey: Self.autoStartDefaultsKey) }
    }

    /// What's on screen: the stored lines, in time order, silences dropped.
    ///
    /// Stored rather than computed. It's read once per visible row plus again for every
    /// "is this the line being spoken?" test, and as a filter-and-sort per read that was
    /// enough to make a long transcript stutter.
    @Published private(set) var lines: [TranscriptSegment] = []

    /// Every line came out of a file beside the audio rather than a recognizer. Worth
    /// saying plainly: text is on screen although nothing has been transcribed here.
    @Published private(set) var isFromSidecar = false

    /// Recorded against segments that came from a file beside the audio rather than a
    /// recognizer, so it's clear nothing was spent making them.
    static let sidecarEngine = "sidecar"

    private static let autoStartDefaultsKey = "transcript.autoStart"
    private static let localeDefaultsKey = "transcript.locale"

    private let transcriptStore = TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private var runTask: Task<Void, Never>?
    private var sidecarTask: Task<Void, Never>?
    /// Set when the stored transcript has moved on from what's beside the audio, so the
    /// sidecar is rewritten once rather than after every pass.
    private var needsSidecarExport = false
    /// Bumped on every stop/start so a cancelled pass can't clear the state of the one
    /// that replaced it.
    private var runGeneration = 0

    private init() {
        startsAutomatically = UserDefaults.standard.bool(forKey: Self.autoStartDefaultsKey)
        localeIdentifier = UserDefaults.standard.string(forKey: Self.localeDefaultsKey)
    }

    // MARK: Display

    private func rebuildLines() {
        let saved = segments.filter { !$0.text.isEmpty }
        lines = saved
        isFromSidecar = !saved.isEmpty && saved.allSatisfy { $0.engine == Self.sidecarEngine }
    }

    /// Binary search rather than a scan: this is asked once per redraw of a list that can
    /// be a thousand lines long, while playback republishes the time twice a second.
    func currentLine(at time: Double) -> TranscriptSegment? {
        var low = 0
        var high = lines.count - 1
        var found: TranscriptSegment?
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].start <= time {
                found = lines[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    var coverageFraction: Double {
        guard duration > 0 else { return segments.isEmpty ? 0 : 1 }
        return min(1, TranscriptCoverage.coveredSeconds(segments) / duration)
    }

    var isComplete: Bool {
        duration > 0 && TranscriptCoverage.gaps(in: segments, duration: duration).isEmpty
    }

    var isRunning: Bool { runningEngine != nil }

    // MARK: Lifecycle

    func attach(track newTrack: Track?) {
        guard track?.id != newTrack?.id else { return }
        cancel()
        track = newTrack
        segments = []
        edits = []
        lastError = nil
        duration = newTrack?.durationMs.map { Double($0) / 1000 } ?? 0
        guard let newTrack else { return }
        segments = (try? transcriptStore.find(trackID: newTrack.id)) ?? []
        edits = (try? transcriptStore.edits(trackID: newTrack.id)) ?? []

        // A transcript already sitting beside the audio is the cheapest one there is, so
        // look before spending anything.
        guard segments.isEmpty else {
            startAutomaticallyIfAsked()
            return
        }
        sidecarTask = Task { [weak self] in
            await self?.importSidecar(track: newTrack)
            guard let self, track?.id == newTrack.id else { return }
            startAutomaticallyIfAsked()
        }
    }

    /// Settings' "transcribe every episode" — an on-device pass, since the other one
    /// spends money and nobody asked for that episode by episode.
    private func startAutomaticallyIfAsked() {
        guard startsAutomatically, !isComplete, !isRunning else { return }
        run(engine: .onDevice)
    }

    /// Only ever when nothing is stored — a file beside the audio must never overwrite
    /// work done here, least of all the user's corrections.
    private func importSidecar(track: Track) async {
        guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else { return }
        let found = await TranscriptSidecar.load(
            track: track, provider: provider, duration: duration > 0 ? duration : nil
        )
        guard let found, !found.isEmpty, self.track?.id == track.id, segments.isEmpty else { return }
        segments = (try? transcriptStore.merge(
            trackID: track.id, incoming: found, engine: Self.sidecarEngine
        )) ?? found
    }

    /// Writes the transcript back beside the audio so it outlives this app. Skipped for
    /// read-only sources, and for transcripts that came from a sidecar untouched.
    private func exportSidecar() {
        guard needsSidecarExport, let track, !lines.isEmpty else { return }
        needsSidecarExport = false
        let snapshot = segments
        let title = track.title
        Task { [weak self] in
            guard let self else { return }
            guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
                  let provider = try? ProviderManager.shared.provider(for: record) else { return }
            do {
                try await TranscriptSidecar.save(
                    snapshot, track: track, provider: provider, title: title, artist: nil
                )
            } catch {
                // Not worth interrupting playback over — the transcript is safe locally
                // and in the backup either way.
                lastError = "Couldn't save the transcript next to the audio: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Running a pass

    /// Transcribes the whole episode with one recogniser. Pressing the one already running
    /// stops it; pressing the other swaps to it.
    func run(engine: TranscriptionEngineKind) {
        guard let track else { return }
        guard runningEngine != engine else {
            cancel()
            return
        }
        cancel()
        lastError = nil
        progress = 0
        runningEngine = engine
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            await self?.transcribeWholeEpisode(track: track, engine: engine)
            guard let self, generation == runGeneration else { return }
            runTask = nil
            runningEngine = nil
            progress = 0
        }
    }

    func cancel() {
        runGeneration += 1
        sidecarTask?.cancel()
        sidecarTask = nil
        runTask?.cancel()
        runTask = nil
        runningEngine = nil
        progress = 0
    }

    private func transcribeWholeEpisode(track: Track, engine: TranscriptionEngineKind) async {
        guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else {
            lastError = "No storage provider configured for this episode."
            return
        }

        let audioURL: URL
        do {
            audioURL = try await AudioWindowFile.audioURL(track: track, provider: provider)
        } catch {
            // On-device recognition itself needs no network, but the audio still has to be
            // readable — so say which half is missing rather than a generic read error.
            lastError = NetworkMonitor.shared.isConnected
                ? "Couldn't read the audio: \(error.localizedDescription)"
                : "You're offline and this episode isn't downloaded yet. Play it once while connected, then on-device transcribing works with no network."
            return
        }
        if duration <= 0 { duration = await AudioWindowFile.duration(of: audioURL) }
        guard duration > 0 else {
            lastError = "Couldn't work out how long this episode is."
            return
        }

        let transcriber = engine.transcriber
        let context = transcriptionContext()
        let windowSeconds = engine.windowSeconds
        let windows = Int(ceil(duration / windowSeconds))
        // Held here, not written, until the last window lands — see the type's note on why
        // a half-finished pass never touches what's already stored.
        var produced: [TranscriptSegment] = []

        for index in 0..<max(windows, 1) {
            guard !Task.isCancelled else { return }
            let window = TimeWindow(
                start: Double(index) * windowSeconds,
                end: min(duration, Double(index + 1) * windowSeconds)
            )
            do {
                produced += try await Self.transcribe(
                    window: window, of: audioURL, using: transcriber, context: context
                )
            } catch {
                guard !Task.isCancelled else { return }
                lastError = "Stopped at \(Int(progress * 100))% — \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, self.track?.id == track.id else { return }
            progress = Double(index + 1) / Double(max(windows, 1))
        }

        guard !Task.isCancelled, self.track?.id == track.id else { return }
        // The one moment anything on disk changes. Merging rather than replacing, so a
        // line the listener corrected survives a re-run with a different recogniser.
        segments = (try? transcriptStore.merge(
            trackID: track.id, incoming: produced, engine: engine.rawValue
        )) ?? TranscriptStore.merging(existing: segments, incoming: produced)
        needsSidecarExport = true
        AutoBackup.shared.markChanged()
        exportSidecar()
    }

    // MARK: Editing

    func applyEdit(to segment: TranscriptSegment, newText: String) {
        guard let track else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        segments = (try? transcriptStore.applyEdit(trackID: track.id, segmentStart: segment.start, newText: trimmed)) ?? segments
        edits = (try? transcriptStore.edits(trackID: track.id)) ?? edits
        needsSidecarExport = true
        AutoBackup.shared.markChanged()
        // A correction is hand-typed and can't be regenerated, so it goes back out at once
        // rather than waiting for the loop to settle.
        exportSidecar()
    }

    nonisolated private static func transcribe(
        window: TimeWindow,
        of sourceURL: URL,
        using transcriber: any SpeechTranscribing,
        context: TranscriptionContext
    ) async throws -> [TranscriptSegment] {
        // Always a freshly decoded window, even when it covers the whole episode: handing a
        // recognizer the original file means handing it whatever container the bucket
        // happened to hold, which is the thing that used to fail.
        let windowURL = try await AudioWindowFile.wavWindow(of: sourceURL, window: window)
        defer { try? FileManager.default.removeItem(at: windowURL) }

        // Partial results are ignored on purpose: nothing is shown until the pass is
        // done, so a half-made line has nowhere to go.
        let lines = try await transcriber.transcribe(
            audioURL: windowURL, startOffset: window.start, context: context
        )
        return Self.padded(lines, toCover: window, engine: transcriber.kind.rawValue)
    }

    /// Whatever the recognizer didn't speak for — leading silence, a trailing music bed,
    /// the whole window if nobody talks — is recorded as an empty line. Without it that
    /// stretch stays a "gap" and gets sent out again on every pass, forever.
    nonisolated static func padded(_ lines: [TranscriptSegment], toCover window: TimeWindow, engine: String) -> [TranscriptSegment] {
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

    /// The language to transcribe this episode in, and where the answer came from.
    ///
    /// Most specific wins: the episode, then its album, then its speaker. A Mandarin
    /// speaker gives a talk in English and one speaker's albums are often in different
    /// languages, so "whose language is this" is the wrong question — it belongs to the
    /// recording, and every level is allowed an answer.
    var inheritedLanguage: (identifier: String, source: LanguageSource)? {
        guard let track else { return nil }
        return Self.resolveLanguage(
            track: track,
            album: track.albumID.flatMap { (try? libraryStore.album(id: $0)) ?? nil },
            artist: track.artistID.flatMap { (try? libraryStore.artist(id: $0)) ?? nil }
        )
    }

    /// Pure, so the rule can be tested without a database or a player: most specific wins.
    nonisolated static func resolveLanguage(track: Track, album: Album?, artist: Artist?) -> (identifier: String, source: LanguageSource)? {
        if let language = track.language { return (language, .episode) }
        if let language = album?.language { return (language, .album) }
        if let language = artist?.language { return (language, .speaker) }
        return nil
    }

    enum LanguageSource: Equatable, Sendable {
        case episode, album, speaker

        var displayName: String {
            switch self {
            case .episode: return "this episode"
            case .album: return "the album"
            case .speaker: return "the speaker"
            }
        }
    }

    /// Records the choice against the episode itself, which is the level that outranks
    /// every other — set where the episode's other details are edited, by someone who has
    /// just heard the audio. Any pass in flight is stopped: it's recognising the wrong
    /// language by definition.
    func setEpisodeLanguage(_ identifier: String?) {
        guard var track else { return }
        track.language = identifier
        try? trackStore.setLanguage(id: track.id, language: identifier)
        self.track = track
        cancel()
    }

    /// This episode's corrections first, then anything recently fixed elsewhere — the same
    /// misheard name usually shows up across a whole show.
    private func transcriptionContext() -> TranscriptionContext {
        let recent = (try? transcriptStore.recentEdits()) ?? []
        let ids = Set(edits.map(\.id))
        var context = TranscriptionContext.from(edits: edits + recent.filter { !ids.contains($0.id) })
        // The episode's own answer, then its album's, then its speaker's, then the
        // app-wide fallback — and only after all of those the phone's language, which is
        // a guess about the listener rather than about the audio.
        context.localeIdentifier = inheritedLanguage?.identifier ?? localeIdentifier
        return context
    }
}
