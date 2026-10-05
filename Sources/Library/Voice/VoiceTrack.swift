import AVFoundation
import Foundation

/// An episode spoken from its transcript by the phone's own voices, laid onto the
/// transcript's timestamps so the highlighted line, seeking and bookmarks still line up.
/// Rendered once into a small file (~15 MB an hour) and played like a download.
enum VoiceTrack {
    static let directory = URL.applicationSupportDirectory.appending(path: "voice", directoryHint: .isDirectory)

    static func url(for trackID: String) -> URL { directory.appending(path: "\(trackID).m4a") }

    static func exists(_ trackID: String) -> Bool { FileManager.default.fileExists(atPath: url(for: trackID).path) }

    static func size(_ trackID: String) -> Int64? {
        (try? url(for: trackID).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    static func remove(_ trackID: String) { try? FileManager.default.removeItem(at: url(for: trackID)) }

    /// What playback should use instead of the original, if anything: the voice track when
    /// the listener picked it, or when there's no original left to play.
    static func playableURL(for track: Track) -> URL? {
        guard track.prefersVoice || track.originalDeletedAt != nil || track.isLost, exists(track.id) else { return nil }
        return url(for: track.id)
    }

    /// The best installed voice for a language: Premium, then Enhanced, then the default.
    static func bestVoice(language: String?) -> AVSpeechSynthesisVoice? {
        let wanted = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == wanted || $0.language.hasPrefix(base + "-") || $0.language == base
        }
        let rank: (AVSpeechSynthesisVoice) -> Int = { voice in
            switch voice.quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return voice.language == wanted ? 1 : 0
            }
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: wanted)
    }

    /// The language the episode is spoken in, as transcription resolves it.
    static func language(for track: Track) -> String? {
        let library = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
        return TranscriptRunner.resolveLanguage(
            track: track,
            album: track.albumID.flatMap { (try? library.album(id: $0)) ?? nil },
            artist: track.artistID.flatMap { (try? library.artist(id: $0)) ?? nil }
        )?.identifier
    }

    /// Whether only the basic voice is installed — the cue to point at Settings.
    static func onlyBasicVoice(language: String?) -> Bool {
        (bestVoice(language: language)?.quality ?? .default) == .default
    }
}

/// Speaks a transcript into a voice track. One render at a time per episode.
@MainActor
final class VoiceRenderer: ObservableObject {
    static let shared = VoiceRenderer()

    /// 0…1 for episodes being rendered right now.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]

    func isRendering(_ trackID: String) -> Bool { progress[trackID] != nil }

    /// Original ⇄ spoken transcript for an episode. The first switch to Voice makes the
    /// voice track; playback moves over by itself once it's ready.
    func setListening(voice: Bool, track: Track) {
        if voice, !VoiceTrack.exists(track.id) { render(track, language: VoiceTrack.language(for: track)) }
        try? TrackStore(dbQueue: DatabaseManager.shared.dbQueue).setPrefersVoice(id: track.id, voice)
        let engine = PlaybackEngine.shared
        engine.showEdit(of: track.id) { $0.prefersVoice = voice }
        var updated = track
        updated.prefersVoice = voice
        if !voice || VoiceTrack.exists(track.id) { engine.reloadCurrent(with: updated) }
    }

    func render(_ track: Track, language: String?) {
        guard progress[track.id] == nil else { return }
        let segments = ((try? TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue).find(trackID: track.id)) ?? nil) ?? []
        guard !segments.isEmpty else {
            errors[track.id] = "This episode has no transcript to speak."
            return
        }
        errors[track.id] = nil
        progress[track.id] = 0
        let voice = VoiceTrack.bestVoice(language: language)
        let trackID = track.id
        Task.detached(priority: .userInitiated) {
            do {
                try await VoiceSynthesis.render(segments: segments, voice: voice, to: VoiceTrack.url(for: trackID)) { fraction in
                    Task { @MainActor in VoiceRenderer.shared.progress[trackID] = fraction }
                }
                await MainActor.run {
                    VoiceRenderer.shared.progress[trackID] = nil
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                    // Asked for from the player: switch to it the moment it exists.
                    let engine = PlaybackEngine.shared
                    if engine.currentTrack?.id == trackID,
                       let fresh = try? TrackStore(dbQueue: DatabaseManager.shared.dbQueue).find(id: trackID),
                       fresh.prefersVoice {
                        engine.reloadCurrent(with: fresh)
                    }
                }
            } catch {
                await MainActor.run {
                    VoiceRenderer.shared.progress[trackID] = nil
                    VoiceRenderer.shared.errors[trackID] = error.localizedDescription
                }
            }
        }
    }
}

/// The rendering itself: each line spoken to memory, sped up a little if it overruns the
/// gap before the next line (at most 1.4×), started at its own timestamp, silence between.
enum VoiceSynthesis {
    private static let sampleRate = 22_050.0
    private static let maxSpeedUp: Float = 1.4

    static func render(
        segments: [TranscriptSegment], voice: AVSpeechSynthesisVoice?, to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw CocoaError(.featureUnsupported)
        }
        try FileManager.default.createDirectory(at: VoiceTrack.directory, withIntermediateDirectories: true)
        // The extension picks the container: "x.m4a.partial" would be written as CAF.
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.m4a")
        try? FileManager.default.removeItem(at: partial)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
        ]
        // Scoped so the file is closed (its header finished) before it's moved into place.
        do {
            let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let synthesizer = AVSpeechSynthesizer()
            let ordered = segments.sorted { $0.start < $1.start }
            var written: AVAudioFramePosition = 0

            for (index, segment) in ordered.enumerated() {
                try Task.checkCancellation()
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                progress(Double(index) / Double(ordered.count))
                guard !text.isEmpty else { continue }

                let slotEnd = index + 1 < ordered.count ? ordered[index + 1].start : max(segment.end, segment.start + 1)
                let slot = max(0.3, slotEnd - segment.start)
                // Rate picked before speaking, from how long the line would take at the normal
                // pace — one pass per line, not a second try when it overruns.
                let estimate = Double(text.count) / charactersPerSecond(language: voice?.language)
                let speedUp = Float(min(max(estimate / slot, 1), Double(maxSpeedUp)))
                let rate = min(AVSpeechUtteranceDefaultSpeechRate * speedUp, AVSpeechUtteranceMaximumSpeechRate)
                let spoken = try await speak(text, voice: voice, rate: rate, synthesizer: synthesizer, format: format)

                let startFrame = AVAudioFramePosition(segment.start * sampleRate)
                if startFrame > written {
                    try writeSilence(frames: startFrame - written, format: format, to: file)
                    written = startFrame
                }
                for buffer in spoken {
                    try file.write(from: buffer)
                    written += AVAudioFramePosition(buffer.frameLength)
                }
            }
        }
        progress(1)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Roughly how fast the default voice talks: Chinese and Japanese characters each carry
    /// a syllable, so far fewer go by per second.
    private static func charactersPerSecond(language: String?) -> Double {
        let code = language?.prefix(2) ?? "en"
        return ["zh", "ja", "ko"].contains(String(code)) ? 4.5 : 14
    }

    private static func writeSilence(frames: AVAudioFramePosition, format: AVAudioFormat, to file: AVAudioFile) throws {
        var left = frames
        let chunk: AVAudioFrameCount = 22_050
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        while left > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), left))
            buffer.frameLength = count
            if let channel = buffer.floatChannelData?[0] { channel.update(repeating: 0, count: Int(count)) }
            try file.write(from: buffer)
            left -= AVAudioFramePosition(count)
        }
    }

    /// One line, spoken to memory and converted to `format`.
    private static func speak(
        _ text: String, voice: AVSpeechSynthesisVoice?, rate: Float, synthesizer: AVSpeechSynthesizer,
        format: AVAudioFormat
    ) async throws -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        let collected = BufferBox()
        synthesizer.delegate = collected
        // Some systems never send the closing empty buffer or the didFinish: a line that's
        // gone quiet is done, rather than the whole render hanging on it.
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if collected.isStalled { collected.finish() }
            }
        }
        defer { watchdog.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            collected.continuation = continuation
            // The last callback is an empty buffer on most systems; the delegate's
            // didFinish covers the ones where it isn't.
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collected.finish()
                    return
                }
                collected.append(pcm)
            }
        }
        synthesizer.delegate = nil
        return try collected.buffers.compactMap { try convert($0, to: format) }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }

    /// The synthesizer calls back on its own queue; this keeps what it hands over and
    /// resumes the waiting line exactly once.
    private final class BufferBox: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AVAudioPCMBuffer] = []
        private var lastActivity = Date()
        var continuation: CheckedContinuation<Void, Never>?

        /// Two quiet seconds after audio started, or ten before any arrived (loading a voice
        /// the first time takes a moment).
        var isStalled: Bool {
            lock.withLock { Date().timeIntervalSince(lastActivity) > (items.isEmpty ? 10 : 2) }
        }

        var buffers: [AVAudioPCMBuffer] { lock.withLock { items } }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                items.append(buffer)
                lastActivity = Date()
            }
        }

        func finish() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finish() }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finish() }
    }
}
