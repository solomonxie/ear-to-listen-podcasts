import Foundation
import UIKit

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
/// Every window is stored the moment it lands, and a pass only ever works on the
/// stretches that have nothing yet (`TranscriptCoverage.windows`). So leaving the app,
/// taking a call, or a recogniser dying mid-episode costs the window in flight and
/// nothing else: coming back picks up at the first hole rather than starting again at
/// zero. Holding the whole pass in memory until the last window read better on paper and
/// meant an hour of recognition thrown away by switching apps.
///
/// **Storing it is not showing it.** While a pass is working the page holds the transcript
/// as it stood when the pass began, and the finished one arrives in one piece. A page that
/// grows a line at a time under the reader — each line a fresh guess at audio they're not
/// listening to yet — is a worse thing to read than a percentage.
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

    /// The transcript as it stood when the running pass began. Nil when nothing is
    /// running, which is when the page follows what's stored again.
    private var frozenLines: [TranscriptSegment]?

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
    @Published private(set) var isFetchingRemote = false
    /// The transcript as it stood before the last pass replaced it, kept only while a
    /// reject is still on offer. This is what makes "Reject" possible at all — a pass
    /// merges over the stored text, and without a copy there is nothing to go back to.
    private var replacedSegments: [TranscriptSegment]?
    /// True while the last finished pass can still be undone.
    @Published private(set) var canRejectLastPass = false
    /// Bumped on every stop/start so a cancelled pass can't clear the state of the one
    /// that replaced it.
    private var runGeneration = 0
    /// The recogniser a pass was using when something other than the listener stopped it —
    /// an error, a window that never came back, the app being put away long enough for the
    /// recognizer to die. Picked up again on the next foreground.
    private var interruptedEngine: TranscriptionEngineKind?
    /// Keeps the app alive a little past leaving it, so the window in flight can finish
    /// and be stored rather than thrown away at the door.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// How many windows in a row may come back with no words before the pass gives up.
    /// A recognizer that has quietly stopped working returns exactly what a silent
    /// stretch does, and the difference matters: silence is recorded as covered and never
    /// looked at again, so believing it on a failing recognizer writes off the episode.
    private static let silentWindowLimit = 6

    private init() {
        localeIdentifier = UserDefaults.standard.string(forKey: Self.localeDefaultsKey)
    }

    // MARK: Display

    private func rebuildLines() {
        let shown = frozenLines ?? segments.filter { !$0.text.isEmpty }
        lines = shown
        isFromSidecar = !shown.isEmpty && shown.allSatisfy { $0.engine == Self.sidecarEngine }
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

    /// How much audio a pass would actually send — the holes, not the episode. A second
    /// run after an interrupted one costs a fraction of the first, and saying so is the
    /// difference between a number someone believes and one they don't.
    var untranscribedSeconds: Double {
        guard duration > 0 else { return 0 }
        return TranscriptCoverage.gaps(in: segments, duration: duration).reduce(0) { $0 + $1.duration }
    }

    /// What this engine would charge for what's left, or nil when nobody is charged.
    func estimatedCost(of engine: TranscriptionEngineKind) -> Double? {
        guard let rate = engine.pricePerMinuteUSD else { return nil }
        return untranscribedSeconds / 60 * rate
    }

    // MARK: Lifecycle

    func attach(track newTrack: Track?) {
        guard track?.id != newTrack?.id else { return }
        cancel()
        track = newTrack
        segments = []
        edits = []
        replacedSegments = nil
        canRejectLastPass = false
        lastError = nil
        duration = newTrack?.durationMs.map { Double($0) / 1000 } ?? 0
        guard let newTrack else { return }
        frozenLines = nil
        segments = (try? transcriptStore.find(trackID: newTrack.id)) ?? []
        edits = (try? transcriptStore.edits(trackID: newTrack.id)) ?? []

        // A transcript already sitting beside the audio is the cheapest one there is, so
        // look before spending anything.
        guard segments.isEmpty else { return }
        // Always, whenever nothing is stored — a recorded path makes it one request
        // instead of a few, but its absence is not evidence there's no transcript.
        sidecarTask = Task { [weak self] in
            await self?.importSidecar(track: newTrack)
        }
    }

    /// The "Remote" button: fetch whatever is beside the audio right now, on purpose.
    ///
    /// Everything else that pulls does so only when there's nothing stored. This is the
    /// one way to say "the bucket's copy changed, go and get it" — for a transcript
    /// written by another device, or one you edited in the bucket by hand.
    func loadRemoteTranscript() {
        guard let track, !isFetchingRemote else { return }
        cancel()
        lastError = nil
        isFetchingRemote = true
        sidecarTask = Task { [weak self] in
            guard let self else { return }
            let before = segments.count
            await importSidecar(track: track, force: true)
            guard self.track?.id == track.id else { return }
            isFetchingRemote = false
            if segments.isEmpty {
                lastError = "No transcript found beside this episode in your storage."
            } else if segments.count == before, !edits.isEmpty {
                lastError = "Kept your edited transcript — remote copies never overwrite corrections."
            }
        }
    }

    /// Pulls the transcript the bucket holds for this episode.
    ///
    /// On opening an episode this runs only when nothing is stored locally — the remote
    /// file is the cheapest transcript there is, but once there's one here, re-reading it
    /// on every open would be a request per episode for a file that rarely changes.
    /// `force` is the transcript button asking again on purpose.
    ///
    /// **A hand edit ends it.** Once the listener has corrected a line, this episode's
    /// text is theirs: the remote copy is never read again and `exportSidecar` writes over
    /// it. That's the trade — remote edits to an episode you've corrected are lost — and
    /// it's the right way round, because the correction is the thing that can't be
    /// regenerated.
    private func importSidecar(track: Track, force: Bool = false) async {
        guard edits.isEmpty else { return }
        guard let record = try? providerStore.all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else { return }
        let found = await TranscriptSidecar.load(
            track: track, provider: provider, duration: duration > 0 ? duration : nil
        )
        guard let found, !found.isEmpty, self.track?.id == track.id else { return }
        guard force || segments.isEmpty else { return }
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
    ///
    /// **Asks the bucket first.** The button means "get me this episode's text", and a
    /// file someone dropped beside the audio — or a corrected copy written by another
    /// device — is both better and free compared to recognising two hours of speech again.
    /// Only when there's nothing there does it spend the battery or the API call.
    /// Skipped once this episode has hand edits, which are never overwritten from remote.
    func run(engine: TranscriptionEngineKind) {
        guard let track else { return }
        guard runningEngine != engine else {
            cancel()
            return
        }
        cancel()
        if edits.isEmpty {
            sidecarTask = Task { [weak self] in
                guard let self else { return }
                await importSidecar(track: track, force: true)
                guard self.track?.id == track.id else { return }
                // Still nothing usable — fall through to actually recognising it.
                if segments.isEmpty { startPass(track: track, engine: engine) }
            }
            return
        }
        startPass(track: track, engine: engine)
    }

    /// Whether starting a pass would write over text that's already here — which makes it
    /// the difference between "transcribe this" and "replace what I have and upload it".
    var wouldReplaceExisting: Bool { !segments.isEmpty }

    /// Puts back what the last pass replaced, and writes that back out. Available only
    /// until the next pass or a change of episode, because the copy it restores from is
    /// only held that long.
    func rejectLastPass() {
        guard let track, let previous = replacedSegments else { return }
        replacedSegments = nil
        canRejectLastPass = false
        try? transcriptStore.save(trackID: track.id, segments: previous)
        segments = previous
        // Straight back out: the rejected one was uploaded when the pass finished, so
        // leaving the bucket holding it would make "reject" a local-only lie.
        needsSidecarExport = true
        exportSidecar()
    }

    private func startPass(track: Track, engine: TranscriptionEngineKind) {
        // Snapshotted before anything merges over it.
        replacedSegments = segments.isEmpty ? nil : segments
        canRejectLastPass = false
        lastError = nil
        progress = 0
        runningEngine = engine
        runGeneration += 1
        let generation = runGeneration
        // Held still for the duration: what lands from here arrives all at once at the end.
        frozenLines = lines
        beginBackgroundAssertion()
        runTask = Task { [weak self] in
            await self?.transcribeWholeEpisode(track: track, engine: engine)
            guard let self, generation == runGeneration else { return }
            runTask = nil
            runningEngine = nil
            progress = 0
            thaw()
            endBackgroundAssertion()
            exportSidecar()
            // Only worth offering when there was something to go back to.
            canRejectLastPass = replacedSegments != nil && !segments.isEmpty
        }
    }

    /// The listener stopping it. Anything else that ends a pass leaves `interruptedEngine`
    /// set, and this is what says they didn't mean to.
    func cancel() {
        interruptedEngine = nil
        stopRunning()
    }

    /// Picks up a pass that stopped on its own — the usual cause being the app being put
    /// away for long enough that the recognizer was taken down with it. Called on every
    /// foreground, and cheap when there's nothing to pick up.
    func resumeIfInterrupted() {
        guard let engine = interruptedEngine, track != nil, !isRunning, !isComplete else { return }
        run(engine: engine)
    }

    private func stopRunning() {
        runGeneration += 1
        sidecarTask?.cancel()
        sidecarTask = nil
        runTask?.cancel()
        runTask = nil
        runningEngine = nil
        progress = 0
        thaw()
        endBackgroundAssertion()
    }

    /// The pass is over, one way or another — the page shows what's actually stored again,
    /// including a part-finished transcript, which is the truth about the episode once
    /// nothing is working on it.
    private func thaw() {
        guard frozenLines != nil else { return }
        frozenLines = nil
        rebuildLines()
    }

    /// Leaving the app suspends it within seconds, which kills the recognizer mid-window.
    /// This buys the window in flight the time to land and be stored.
    private func beginBackgroundAssertion() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "transcribe") { [weak self] in
            self?.interruptedEngine = self?.runningEngine
            self?.stopRunning()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
        // Only the stretches with nothing in them yet, front to back. This is what makes
        // coming back cheap: whatever an interrupted pass already stored is never sent out
        // a second time.
        let plan = TranscriptCoverage.windows(
            in: segments, duration: duration, windowSeconds: windowSeconds, from: 0
        )
        guard !plan.isEmpty else { return }

        // Windows that came back with nothing are held rather than stored: a stretch
        // recorded as silence is a stretch nothing will ever look at again, and a
        // recognizer that has stopped working looks exactly like a quiet one.
        var unheard: [TranscriptSegment] = []
        var silentInARow = 0

        for (index, window) in plan.enumerated() {
            guard !Task.isCancelled else { return }
            let produced: [TranscriptSegment]
            do {
                produced = try await Self.transcribe(
                    window: window, of: audioURL, using: transcriber, context: context
                )
            } catch {
                guard !Task.isCancelled else { return }
                // Not a dead end: what's already stored stands, and the next foreground
                // picks the pass up at this window.
                interruptedEngine = engine
                lastError = "Stopped at \(Int(progress * 100))% — \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, self.track?.id == track.id else { return }

            if produced.contains(where: { !$0.text.isEmpty }) {
                // Something was heard, so the quiet windows before it really were quiet.
                store(unheard + produced, for: track, engine: engine)
                unheard = []
                silentInARow = 0
            } else {
                unheard += produced
                silentInARow += 1
                guard silentInARow < Self.silentWindowLimit else {
                    interruptedEngine = engine
                    lastError = "Stopped — nothing was recognised in \(Int(Double(Self.silentWindowLimit) * windowSeconds / 60)) minutes of audio. Check the episode's language, or try the other recogniser."
                    return
                }
            }
            progress = Double(index + 1) / Double(plan.count)
        }

        guard !Task.isCancelled, self.track?.id == track.id else { return }
        // A pass that ran to the end proves the recognizer was working, so a quiet tail is
        // genuinely quiet and can be recorded as covered.
        if !unheard.isEmpty { store(unheard, for: track, engine: engine) }
        interruptedEngine = nil
    }

    /// One window, onto disk, the moment it's done. Merging rather than replacing, so a
    /// line the listener corrected survives a re-run with a different recogniser.
    private func store(_ produced: [TranscriptSegment], for track: Track, engine: TranscriptionEngineKind) {
        segments = (try? transcriptStore.merge(
            trackID: track.id, incoming: produced, engine: engine.rawValue
        )) ?? TranscriptStore.merging(existing: segments, incoming: produced)
        needsSidecarExport = true
    }

    // MARK: Editing

    func applyEdit(to segment: TranscriptSegment, newText: String) {
        guard let track else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        segments = (try? transcriptStore.applyEdit(
            trackID: track.id, segmentStart: segment.start, newText: trimmed
        )) ?? segments
        edits = (try? transcriptStore.edits(trackID: track.id)) ?? edits
        needsSidecarExport = true
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
