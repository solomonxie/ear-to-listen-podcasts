import AVFoundation
import Foundation

/// Gets one window of an episode's audio into a form a recognizer will accept.
///
/// Both engines take a file, not a time range, so a window has to be cut out first. That
/// used to go through `AVAssetExportSession` writing an m4a, which is the wrong tool twice
/// over: it refuses outright on some MP3s, and it reads the source's container from the
/// file extension — which the audio cache didn't keep, so a downloaded episode could play
/// and still be untranscribable. Decoding to PCM with `AVAssetReader` and writing a WAV
/// sidesteps both: the reader decodes whatever the asset actually is, and a WAV is the one
/// format neither recognizer can misread.
///
/// The asset is also read in place rather than downloaded first — `AVAssetReader` pulls
/// only the byte ranges a window needs over HTTP, so transcribing can start on an episode
/// that's never been played.
enum AudioWindowFile {
    /// 16 kHz mono is what speech recognition wants either way, and it keeps a Whisper-sized
    /// window comfortably under its upload limit.
    private static let sampleRate = 16_000
    private static let channels = 1
    private static let bitsPerSample = 16

    /// Where to read this episode from: the cached copy when there is one, otherwise the
    /// provider's stream URL. A URL rather than a ready-made `AVAsset` because an asset
    /// isn't `Sendable` — every reader here builds its own from this.
    static func audioURL(track: Track, provider: CloudProvider) async throws -> URL {
        if let cached = await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) {
            return cached
        }
        return try await provider.streamURL(forFileID: track.filePath)
    }

    /// Downloads the whole episode into the playback cache. Transcribing doesn't need this
    /// (it reads ranges in place) — it's for callers that want a local copy to keep.
    static func localURL(track: Track, provider: CloudProvider) async throws -> URL {
        if let cached = await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) {
            return cached
        }
        let remote = try await provider.streamURL(forFileID: track.filePath)
        if remote.isFileURL { return remote }
        return try await AudioCache.shared.store(remoteURL: remote, providerID: track.providerID, filePath: track.filePath)
    }

    static func duration(of url: URL) async -> Double {
        let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
        guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    /// Decodes `window` to a WAV in the temporary directory. The caller owns the file and
    /// should delete it.
    static func wavWindow(of url: URL, window: TimeWindow) async throws -> URL {
        let samples = try await pcmSamples(of: AVURLAsset(url: url), window: window)
        guard !samples.isEmpty else { throw TranscriptionError.sliceFailed }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString).wav")
        try wavContainer(around: samples).write(to: url)
        return url
    }

    private static func pcmSamples(of asset: AVAsset, window: TimeWindow) async throws -> Data {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriptionError.sliceFailed
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            duration: CMTime(seconds: window.duration, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitsPerSample,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw TranscriptionError.sliceFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriptionError.sliceFailed }

        var samples = Data()
        while let buffer = output.copyNextSampleBuffer() {
            // Decoding a window is most of the wait on a remote file; a listener who has
            // already jumped somewhere else shouldn't have to sit through the rest of it.
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer else { continue }
            pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                samples.append($0, count: length)
            }
        }
        if reader.status == .failed { throw reader.error ?? TranscriptionError.sliceFailed }
        return samples
    }

    /// A 44-byte canonical WAV header in front of the samples.
    private static func wavContainer(around samples: Data) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let blockAlign = channels * bitsPerSample / 8
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * blockAlign))
        append(UInt16(blockAlign))
        append(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }
}
