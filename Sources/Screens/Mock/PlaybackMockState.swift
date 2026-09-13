import AVFoundation

/// Drives the podcast UI/UX demo: real `AVAudioPlayer` playback over a few
/// bundled clips (`Resources/DemoAudio`), so play/pause/seek/transcript
/// highlighting all work without a wired-up remote source. Not the real
/// playback engine — see `Sources/Playback/PlaybackEngine.swift` for that.
@MainActor
final class PlaybackMockState: NSObject, ObservableObject {
    static let shared = PlaybackMockState()

    @Published private(set) var currentEpisode: PodcastEpisode?
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var queue: [PodcastEpisode] = []
    @Published private(set) var currentTranscriptLineID: Double?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ episode: PodcastEpisode, queue: [PodcastEpisode] = []) {
        currentEpisode = episode
        self.queue = queue.isEmpty ? [episode] : queue
        stopTimer()

        guard let name = episode.audioFileName,
              let url = Bundle.main.url(forResource: name, withExtension: "m4a") else {
            player = nil
            duration = Double(episode.durationSeconds)
            progress = 0
            isPlaying = false
            currentTranscriptLineID = nil
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            player = newPlayer
            duration = newPlayer.duration
            progress = 0
            newPlayer.play()
            isPlaying = true
            startTimer()
        } catch {
            player = nil
            isPlaying = false
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: Double) {
        progress = time
        player?.currentTime = time
        updateTranscriptLine()
    }

    func skipToNext() {
        guard let current = currentEpisode, let index = queue.firstIndex(of: current), index + 1 < queue.count else { return }
        play(queue[index + 1], queue: queue)
    }

    func skipToPrevious() {
        guard let current = currentEpisode, let index = queue.firstIndex(of: current), index > 0 else { return }
        play(queue[index - 1], queue: queue)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        progress = player.currentTime
        updateTranscriptLine()
    }

    private func updateTranscriptLine() {
        guard let episode = currentEpisode else { return }
        currentTranscriptLineID = episode.transcript.last { $0.startSeconds <= progress }?.id
    }
}

extension PlaybackMockState: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = self.duration
            self.skipToNext()
        }
    }
}
