import Foundation

/// Owns the transcript of whatever's playing: what's already stored, what's being filled
/// in right now, and the user's corrections.
///
/// The loop is gap-driven rather than file-driven. Everything already transcribed —
/// including a half-finished episode from a previous session — is left alone, and only the
/// uncovered stretches are sent out, nearest the playhead first, so listening from the
/// middle starts producing text immediately. Every window is saved as it lands, so
/// quitting mid-episode keeps what got done.
///
/// It also keeps chasing the playhead *while* a window is in flight: jump somewhere else
/// and the window being worked on is dropped mid-way for the one you actually landed on.
/// And engines that can stream publish their half-made lines as `draft`, so text appears
/// as it's recognised instead of a window at a time.
@MainActor
final class LiveTranscript: ObservableObject {
    static let shared = LiveTranscript()

    @Published private(set) var track: Track?
    @Published private(set) var segments: [TranscriptSegment] = [] {
        didSet { rebuildLines() }
    }
    @Published private(set) var edits: [TranscriptEdit] = []
    @Published private(set) var activeWindow: TimeWindow?
    /// What the running engine has made out but not finished with. Never saved — the
    /// merge when the window completes is what makes it permanent. Split into lines that
    /// have stopped moving and a tail that hasn't, because the tail rewrites itself
    /// several times a second and must not churn the list around it.
    @Published private(set) var draft = TranscriptDraft() {
        didSet { rebuildLines() }
    }
    @Published private(set) var isWorking = false
    /// Idle on purpose, waiting for playback to start again — not stuck, and not off.
    @Published private(set) var isWaitingForPlayback = false
    @Published private(set) var lastError: String?
    @Published private(set) var duration: Double = 0

    /// What language the audio is in. Nil means "whatever the phone is set to", which is
    /// only ever a guess — someone with an English phone listening to a Mandarin show got
    /// the en-US recognizer and an endless stream of nonsense out of it.
    @Published var localeIdentifier: String? {
        didSet {
            UserDefaults.standard.set(localeIdentifier, forKey: Self.localeDefaultsKey)
            guard localeIdentifier != oldValue else { return }
            restart()
        }
    }

    @Published var engineKind: TranscriptionEngineKind {
        didSet {
            UserDefaults.standard.set(engineKind.rawValue, forKey: Self.engineDefaultsKey)
            guard engineKind != oldValue else { return }
            restart()
        }
    }

    /// Whether this episode is being transcribed as it plays. Not remembered per episode:
    /// transcribing spends battery or money, so each one starts from `startsAutomatically`
    /// — off unless the listener has said in Settings that they want every episode done.
    /// Whatever was transcribed before is shown either way, so nothing is lost by asking.
    @Published var isLiveEnabled = false {
        didSet {
            guard isLiveEnabled != oldValue else { return }
            isLiveEnabled ? restart() : stop()
        }
    }

    /// The answer to "every episode, or only the ones I ask for?", set once in Settings.
    @Published var startsAutomatically: Bool {
        didSet { UserDefaults.standard.set(startsAutomatically, forKey: Self.autoStartDefaultsKey) }
    }

    /// Whether to keep transcribing an episode nobody is listening to. Off by default:
    /// the loop otherwise runs the whole way through a paused episode, spending battery
    /// (and, on Whisper, money) on audio the listener walked away from. A window already
    /// in flight when playback pauses is still finished — throwing it away would mean
    /// redoing it on every pause.
    ///
    /// Driven by `toggleWholeEpisode()` rather than a switch of its own: "run the whole
    /// thing now" and "stop running ahead" are the two things anyone actually wants, and
    /// they are one button.
    @Published var runsWhilePaused: Bool {
        didSet { UserDefaults.standard.set(runsWhilePaused, forKey: Self.whilePausedDefaultsKey) }
    }

    /// Transcribing the whole episode under its own steam, rather than following the
    /// playhead.
    var isRunningAhead: Bool { isLiveEnabled && runsWhilePaused }

    /// The one manual control: transcribe the rest of the episode now, or stop doing so.
    /// Starting it turns the transcript on if it was off, so it's a single tap from a
    /// cold episode to "do all of this".
    func toggleWholeEpisode() {
        if isRunningAhead {
            runsWhilePaused = false
            return
        }
        runsWhilePaused = true
        // `start()` is a no-op while a pass is already in flight — one that was merely
        // waiting for playback picks the change up on its own poll.
        if isLiveEnabled { start() } else { isLiveEnabled = true }
    }

    /// Recorded against segments that came from a file beside the audio rather than a
    /// recognizer, so it's clear nothing was spent making them.
    static let sidecarEngine = "sidecar"

    private static let engineDefaultsKey = "transcript.engine"
    private static let autoStartDefaultsKey = "transcript.autoStart"
    private static let localeDefaultsKey = "transcript.locale"
    private static let whilePausedDefaultsKey = "transcript.whilePaused"

    private let transcriptStore = TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private var fillTask: Task<Void, Never>?
    private var sidecarTask: Task<Void, Never>?
    /// Set when the stored transcript has moved on from what's beside the audio, so the
    /// sidecar is rewritten once rather than after every window.
    private var needsSidecarExport = false
    /// Bumped on every stop/start so a cancelled pass can't clear the state of the one
    /// that replaced it.
    private var fillGeneration = 0

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.engineDefaultsKey) ?? ""
        engineKind = TranscriptionEngineKind(rawValue: stored) ?? .onDevice
        runsWhilePaused = UserDefaults.standard.bool(forKey: Self.whilePausedDefaultsKey)
        startsAutomatically = UserDefaults.standard.bool(forKey: Self.autoStartDefaultsKey)
        localeIdentifier = UserDefaults.standard.string(forKey: Self.localeDefaultsKey)
    }

    // MARK: Display

    /// What's on screen: the saved lines with the in-flight ones folded in, in time order.
    ///
    /// Stored rather than computed. A running transcription republishes `draft` several
    /// times a second, and this list is read once per visible row plus again for every
    /// "is this the current line?" test — as a computed property that was a filter and a
    /// sort per read, which is what made the page stutter and flash while transcribing.
    /// Silent stretches are stored as empty lines — that's how "listened to, nothing said"
    /// is remembered — and dropped here.
    @Published private(set) var lines: [TranscriptSegment] = []

    /// Starts of the lines still being revised, as a set: the row view asks this per row.
    private var provisionalStarts: Set<Double> = []

    /// Every line came out of a file beside the audio rather than a recognizer. Worth
    /// saying plainly: text is on screen while the engine menu still reads "Off", and
    /// those two facts look contradictory otherwise.
    @Published private(set) var isFromSidecar = false

    private func rebuildLines() {
        let saved = segments.filter { !$0.text.isEmpty }
        let settled = draft.settled
        provisionalStarts = Set(settled.map(\.start))
        lines = settled.isEmpty ? saved : (saved + settled).sorted { $0.start < $1.start }
        isFromSidecar = !saved.isEmpty && saved.allSatisfy { $0.engine == Self.sidecarEngine }
    }

    /// The moving tail, as phrases. Carries no timestamps — every word in it can still be
    /// rewritten, so it can't be tapped to seek and doesn't belong in the list proper.
    var volatilePhrases: [String] { draft.volatile }

    func isProvisional(_ segment: TranscriptSegment) -> Bool {
        provisionalStarts.contains(segment.start)
    }

    /// Binary search rather than a scan: this is asked once per redraw of a list that can
    /// be a thousand lines long, while playback is republishing the time twice a second.
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

    // MARK: Lifecycle

    func attach(track newTrack: Track?) {
        guard track?.id != newTrack?.id else { return }
        stop()
        // A new episode is a new decision, unless Settings says otherwise.
        isLiveEnabled = startsAutomatically
        track = newTrack
        segments = []
        edits = []
        draft = TranscriptDraft()
        lastError = nil
        duration = newTrack?.durationMs.map { Double($0) / 1000 } ?? 0
        guard let newTrack else { return }
        segments = (try? transcriptStore.find(trackID: newTrack.id)) ?? []
        edits = (try? transcriptStore.edits(trackID: newTrack.id)) ?? []

        // A transcript already sitting beside the audio is the cheapest one there is, so
        // look before spending anything. Deliberately sequenced ahead of the fill loop:
        // starting both at once would have them racing to fill the same gaps.
        guard segments.isEmpty else {
            if isLiveEnabled { start() }
            return
        }
        sidecarTask = Task { [weak self] in
            await self?.importSidecar(track: newTrack)
            guard let self, track?.id == newTrack.id, isLiveEnabled else { return }
            start()
        }
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
            isWaitingForPlayback = false
            activeWindow = nil
            draft = TranscriptDraft()
        }
    }

    func stop() {
        fillGeneration += 1
        sidecarTask?.cancel()
        sidecarTask = nil
        fillTask?.cancel()
        fillTask = nil
        isWorking = false
        isWaitingForPlayback = false
        activeWindow = nil
        draft = TranscriptDraft()
    }

    /// After a failure the loop gives up rather than hammering a broken provider, so
    /// getting going again is an explicit ask.
    func retry() {
        lastError = nil
        restart()
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
        draft = TranscriptDraft()
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
        needsSidecarExport = true
        AutoBackup.shared.markChanged()
        // A correction is hand-typed and can't be regenerated, so it goes back out at once
        // rather than waiting for the loop to settle.
        exportSidecar()
    }

    // MARK: Filling

    private func fillGaps(track: Track) async {
        guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else {
            lastError = "No storage provider configured for this episode."
            return
        }

        isWorking = true
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

        let transcriber = engineKind.transcriber
        let context = transcriptionContext()

        while !Task.isCancelled {
            await awaitPlayback()
            guard !Task.isCancelled else { return }
            guard let window = nextWindow() else { break }
            activeWindow = window
            draft = TranscriptDraft()
            do {
                let produced = try await transcribeChasingPlayhead(
                    window: window, of: audioURL, using: transcriber, context: context
                )
                guard !Task.isCancelled, self.track?.id == track.id else { return }
                draft = TranscriptDraft()
                // Abandoned for somewhere the listener actually is: nothing to save, and
                // the next pass picks the window around the new position.
                guard let produced else { continue }
                segments = (try? transcriptStore.merge(
                    trackID: track.id, incoming: produced, engine: engineKind.rawValue
                )) ?? TranscriptStore.merging(existing: segments, incoming: produced)
                needsSidecarExport = true
                AutoBackup.shared.markChanged()
            } catch {
                draft = TranscriptDraft()
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                return
            }
        }
        draft = TranscriptDraft()
        exportSidecar()
    }

    /// Holds the loop while the episode is paused, unless the listener asked for it to
    /// keep going. Polled rather than observed: the wait is idle either way, and the loop
    /// is a plain `async` task with nowhere to hang a subscription.
    private func awaitPlayback() async {
        guard !runsWhilePaused, !PlaybackEngine.shared.isPlaying else { return }
        isWaitingForPlayback = true
        isWorking = false
        while !Task.isCancelled, !runsWhilePaused, !PlaybackEngine.shared.isPlaying {
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        isWaitingForPlayback = false
        isWorking = !Task.isCancelled
    }

    /// The uncovered stretch worth doing next: the one under the playhead, or the nearest
    /// one after it, falling back to what's behind once everything ahead is done.
    private func nextWindow() -> TimeWindow? {
        TranscriptCoverage.windows(
            in: segments,
            duration: duration,
            windowSeconds: engineKind.windowSeconds,
            from: PlaybackEngine.shared.currentTime
        ).first
    }

    /// Runs one window, watching the playhead as it goes. Returns `nil` when the listener
    /// moved somewhere this window no longer serves, in which case it was cancelled and
    /// produced nothing.
    private func transcribeChasingPlayhead(
        window: TimeWindow, of sourceURL: URL, using transcriber: any SpeechTranscribing, context: TranscriptionContext
    ) async throws -> [TranscriptSegment]? {
        let job = Task { [weak self] in
            try await Self.transcribe(window: window, of: sourceURL, using: transcriber, context: context) { partial in
                Task { @MainActor in self?.acceptDraft(partial, for: window) }
            }
        }
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                if self.hasMovedOn(from: window) {
                    job.cancel()
                    return
                }
            }
        }
        defer { watcher.cancel() }

        do {
            return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        } catch is CancellationError {
            return nil
        }
    }

    private func hasMovedOn(from window: TimeWindow) -> Bool {
        !TranscriptCoverage.isWorthFinishing(
            window,
            in: segments,
            duration: duration,
            windowSeconds: engineKind.windowSeconds,
            playhead: PlaybackEngine.shared.currentTime
        )
    }

    private func acceptDraft(_ incoming: TranscriptDraft, for window: TimeWindow) {
        guard activeWindow == window, incoming != draft else { return }
        // A revision that makes out nothing is a normal thing for the recognizer to
        // report mid-window, but letting it through empties the pane and refills it a
        // moment later — the text visibly blinks out. The window's own result is what
        // clears the draft.
        guard !(incoming.isEmpty && !draft.isEmpty) else { return }
        draft = incoming
    }

    nonisolated private static func transcribe(
        window: TimeWindow,
        of sourceURL: URL,
        using transcriber: any SpeechTranscribing,
        context: TranscriptionContext,
        onPartial: @escaping @Sendable (TranscriptDraft) -> Void
    ) async throws -> [TranscriptSegment] {
        // Always a freshly decoded window, even when it covers the whole episode: handing a
        // recognizer the original file means handing it whatever container the bucket
        // happened to hold, which is the thing that used to fail.
        let windowURL = try await AudioWindowFile.wavWindow(of: sourceURL, window: window)
        defer { try? FileManager.default.removeItem(at: windowURL) }

        let lines = try await transcriber.transcribe(
            audioURL: windowURL, startOffset: window.start, context: context, onPartial: onPartial
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

    /// This episode's corrections first, then anything recently fixed elsewhere — the same
    /// misheard name usually shows up across a whole show.
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
    /// every other — set from the transcript pane, where someone has just heard the audio.
    func setEpisodeLanguage(_ identifier: String?) {
        guard var track else { return }
        track.language = identifier
        try? trackStore.setLanguage(id: track.id, language: identifier)
        self.track = track
        restart()
    }

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
