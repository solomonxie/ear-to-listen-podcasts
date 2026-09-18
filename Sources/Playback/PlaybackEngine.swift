import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PlaybackEngine: ObservableObject {
    static let shared = PlaybackEngine()

    @Published private(set) var currentTrack: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?
    /// Raised when the listener picked an episode themselves, so the root can bring the
    /// full player up with it.
    @Published var isPresentingPlayer = false

    /// Where the next load should start, when something asked for a particular moment
    /// rather than "carry on where I was".
    private var pendingStart: TimeInterval?

    private let player = AVQueuePlayer()
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private var itemStatusObservation: NSKeyValueObservation?
    private var hasRetriedCurrentTrack = false
    private var lastPersistedProgressAt = Date.distantPast

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
        observeLibraryChanges()
    }

    /// An episode can be renamed or re-arted (`EpisodeEditView`) while it's playing, so
    /// re-read the rows behind the player — title, artwork and lock screen follow the
    /// edit, playback itself is left alone.
    private func observeLibraryChanges() {
        NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadTrackMetadata() }
        }
    }

    private func reloadTrackMetadata() {
        queue = queue.map { ((try? trackStore.find(id: $0.id)) ?? nil) ?? $0 }
        guard let current = currentTrack else { return }
        currentTrack = queue.first { $0.id == current.id } ?? ((try? trackStore.find(id: current.id)) ?? nil) ?? current
        if let track = currentTrack { updateNowPlayingInfo(track: track) }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            lastError = "Audio session error: \(error.localizedDescription)"
        }
    }

    func play(track: Track, queue newQueue: [Track] = []) {
        persistProgress(force: true)
        queue = newQueue.isEmpty ? [track] : newQueue
        currentTrack = track
        hasRetriedCurrentTrack = false
        try? trackStore.touchLastPlayed(id: track.id)
        TranscriptRunner.shared.attach(track: track)
        Task { await loadAndPlay(track: track) }
    }

    private func loadAndPlay(track: Track) async {
        do {
            guard let record = try providerStore.all().first(where: { $0.id == track.providerID }) else {
                lastError = "No storage provider configured for this track."
                return
            }
            let provider = try ProviderManager.shared.provider(for: record)
            let isCached = await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) != nil
            guard NetworkMonitor.shared.isConnected || isCached else {
                lastError = "You're offline. Connect to the internet to stream this track."
                return
            }
            let url = try await resolvedStreamURL(track: track, provider: provider)
            let item = AVPlayerItem(url: url)
            observeStatus(of: item, track: track)
            player.removeAllItems()
            player.insert(item, after: nil)
            seekToStart(of: track)
            player.play()
            isPlaying = true
            lastError = nil
            updateNowPlayingInfo(track: track)
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
        }
    }

    /// Where this load should begin: the moment something asked for, otherwise wherever
    /// playback last left off.
    private func seekToStart(of track: Track) {
        guard let pendingStart else {
            seekToResumePosition(of: track)
            return
        }
        self.pendingStart = nil
        seek(to: pendingStart)
    }

    /// Resumes from where playback last left off, unless the track was already finished.
    private func seekToResumePosition(of track: Track) {
        guard let positionMs = track.positionMs, positionMs > 2_000 else { return }
        if let durationMs = track.durationMs, positionMs >= durationMs - 5_000 { return }
        player.seek(to: CMTime(seconds: TimeInterval(positionMs) / 1000, preferredTimescale: 600))
    }

    /// A presigned stream URL can expire mid-playback (e.g. a long pause). On failure, drop any
    /// cached copy and retry once with a freshly resolved URL before giving up.
    private func observeStatus(of item: AVPlayerItem, track: Track) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in await self?.handlePlaybackFailure(track: track) }
        }
    }

    private func handlePlaybackFailure(track: Track) async {
        guard currentTrack?.id == track.id else { return }
        guard !hasRetriedCurrentTrack else {
            isPlaying = false
            lastError = NetworkMonitor.shared.isConnected
                ? "Playback failed: couldn't load this track."
                : "You're offline. Connect to the internet to stream this track."
            return
        }
        hasRetriedCurrentTrack = true
        await AudioCache.shared.invalidate(providerID: track.providerID, filePath: track.filePath)
        await loadAndPlay(track: track)
    }

    /// Cache hit plays straight from disk. On a miss, streams from the provider immediately
    /// (no playback delay) and downloads a copy in the background for next time — local
    /// files are already on-disk, so those are never cached.
    private func resolvedStreamURL(track: Track, provider: CloudProvider) async throws -> URL {
        if let cached = await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) {
            return cached
        }
        let remote = try await provider.streamURL(forFileID: track.filePath)
        guard !remote.isFileURL else { return remote }
        Task.detached {
            try? await AudioCache.shared.store(remoteURL: remote, providerID: track.providerID, filePath: track.filePath)
        }
        return remote
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
        persistProgress(force: true)
    }

    func resume() {
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
    }

    /// Starts playback *because someone tapped this episode*, and opens the player with
    /// it. Deliberately separate from `play`: finishing an episode auto-advances through
    /// the same `play`, and that must never throw the full player over whatever you were
    /// doing. Five list screens called `play` directly and only two of them opened the
    /// player, so tapping an episode inside an album looked like nothing happened.
    func open(track: Track, queue: [Track]) {
        play(track: track, queue: queue)
        isPresentingPlayer = true
    }

    /// Opens an episode at a saved moment — a bookmark tapped from Home or an album page.
    /// Beats the resume position for this one load, which is the whole point of having
    /// marked the spot.
    func open(track: Track, queue: [Track], startingAt position: TimeInterval) {
        if currentTrack?.id == track.id {
            seek(to: position)
            resume()
        } else {
            pendingStart = position
            play(track: track, queue: queue)
        }
        isPresentingPlayer = true
    }

    func seek(to time: TimeInterval) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    func skipToNext() {
        guard let current = currentTrack,
              let index = queue.firstIndex(where: { $0.id == current.id }),
              index + 1 < queue.count else { return }
        play(track: queue[index + 1], queue: queue)
    }

    func skipToPrevious() {
        guard let current = currentTrack,
              let index = queue.firstIndex(where: { $0.id == current.id }),
              index > 0 else { return }
        play(track: queue[index - 1], queue: queue)
    }

    private func observeTime() {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite { self.currentTime = time.seconds }
                // `duration` is NaN (indefinite) until the asset finishes resolving it — e.g.
                // while a real, possibly-VBR mp3 is still parsing. Feeding that straight into
                // the now-playing slider's range (`0...duration`) crashes it.
                let rawDuration = self.player.currentItem?.duration.seconds ?? 0
                self.duration = rawDuration.isFinite ? rawDuration : 0
                self.updateNowPlayingElapsedTime()
                self.persistProgress()
            }
        }
    }

    /// Throttled so scrubbing/seeking doesn't hammer the database; `force` bypasses that
    /// for moments that matter (pause, track switch).
    private func persistProgress(force: Bool = false) {
        guard let track = currentTrack, currentTime.isFinite, currentTime >= 0 else { return }
        guard force || Date().timeIntervalSince(lastPersistedProgressAt) > 5 else { return }
        lastPersistedProgressAt = Date()
        try? trackStore.recordProgress(id: track.id, positionMs: Int(currentTime * 1000))
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToNext() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipToPrevious() }
            return .success
        }
    }

    private func updateNowPlayingInfo(track: Track) {
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title]
        if let url = ImageFileStore.artwork.url(for: track.artworkFileName),
           let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(image)
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// `MPMediaItemArtwork` asks for the picture on a queue of its own, and a closure
    /// written inside this main-actor class inherits the main actor — so the request
    /// handler trapped (`EXC_BREAKPOINT` in `swift_task_isCurrentExecutor`) the moment
    /// MediaPlayer called it off the main thread. That is why giving an episode artwork
    /// made it kill the app on the next play. Built out here, `nonisolated`, where there
    /// is no isolation to inherit. MediaPlayer's blocks aren't `Sendable`-audited, so
    /// nothing warns about this at compile time.
    nonisolated static func nowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlayingElapsedTime() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
