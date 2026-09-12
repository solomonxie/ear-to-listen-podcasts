import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class PlaybackEngine: ObservableObject {
    static let shared = PlaybackEngine()

    @Published private(set) var currentTrack: Track?
    @Published private(set) var queue: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lastError: String?

    private let player = AVQueuePlayer()
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)

    private init() {
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
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
        queue = newQueue.isEmpty ? [track] : newQueue
        currentTrack = track
        Task { await loadAndPlay(track: track) }
    }

    private func loadAndPlay(track: Track) async {
        do {
            guard let record = try providerStore.all().first(where: { $0.id == track.providerID }) else {
                lastError = "No storage provider configured for this track."
                return
            }
            let provider = try ProviderManager.shared.provider(for: record)
            let url = try await provider.streamURL(forFileID: track.filePath)
            let item = AVPlayerItem(url: url)
            player.removeAllItems()
            player.insert(item, after: nil)
            player.play()
            isPlaying = true
            lastError = nil
            updateNowPlayingInfo(track: track)
        } catch {
            lastError = "Playback failed: \(error.localizedDescription)"
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    func resume() {
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
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
                self.currentTime = time.seconds
                self.duration = self.player.currentItem?.duration.seconds ?? 0
                self.updateNowPlayingElapsedTime()
            }
        }
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
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
