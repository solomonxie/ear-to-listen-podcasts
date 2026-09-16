import AVFoundation
import Foundation

/// Gets an episode's audio onto disk and cuts out the one window a recognizer is being
/// asked about. Both engines take a file, not a time range, so filling a gap without
/// re-reading the whole episode means physically exporting that slice first.
enum AudioWindowFile {
    /// Reuses the playback disk cache, so transcribing also warms it for playback.
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

    /// Exports `window` to a temporary m4a. The caller owns the file and should delete it.
    static func slice(of url: URL, window: TimeWindow) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard
            let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw TranscriptionError.sliceFailed
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-\(UUID().uuidString).m4a")
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            duration: CMTime(seconds: window.duration, preferredTimescale: 600)
        )
        try await export(session: session, to: output)
        return output
    }

    private static func export(session: AVAssetExportSession, to output: URL) async throws {
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
            return
        }
        session.outputURL = output
        session.outputFileType = .m4a
        nonisolated(unsafe) let session = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error ?? TranscriptionError.sliceFailed)
                }
            }
        }
    }
}
