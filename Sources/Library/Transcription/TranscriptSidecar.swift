import Foundation

/// Moves transcripts between the app and the plain files beside the audio in the user's
/// own storage.
///
/// Reading first, because it's the cheapest transcript there is: plenty of shows already
/// publish one, and finding `ep1.vtt` next to `ep1.mp3` means that episode is done the
/// moment it syncs — no battery spent, no API billed, nothing to wait through.
///
/// Writing puts what this app made back where other tools can read it, so a transcript
/// isn't trapped in one app's database. `.vtt` is the one read back; the `.lrc` beside it
/// is for lyrics-aware players.
enum TranscriptSidecar {
    /// The first sidecar that parses into something usable. Missing files are the normal
    /// case, not an error — most episodes won't have one.
    /// Reads the sidecar the last sync recorded beside this episode. Nothing to read is
    /// the normal case, not an error — most episodes won't have one.
    ///
    /// The path comes from `Track.transcriptPath`, learned from the listing rather than
    /// guessed: probing five candidate extensions per episode was five requests to be
    /// told "no" four or five times, every time.
    static func load(track: Track, provider: CloudProvider, duration: Double?) async -> [TranscriptSegment]? {
        guard let path = track.transcriptPath?.nilIfEmpty else { return nil }
        guard let text = await contents(at: path, provider: provider) else { return nil }
        let segments = TranscriptFile.parse(
            text, extension: (path as NSString).pathExtension, duration: duration
        )
        return segments.isEmpty ? nil : segments
    }

    /// Writes both files. Throws only on a write that was attempted and failed — a
    /// read-only source is a normal answer, not a problem to report.
    static func save(
        _ segments: [TranscriptSegment], track: Track, provider: CloudProvider, title: String?, artist: String?
    ) async throws {
        guard provider.isWritable else { return }
        let lines = segments.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return }

        if let path = TranscriptFile.sidecarPath(
            forAudioPath: track.filePath, extension: TranscriptFile.canonicalExtension
        ) {
            let vtt = TranscriptFile.vtt(from: segments)
            try await provider.upload(Data(vtt.utf8), toPath: path, contentType: "text/vtt")
        }

        if let path = TranscriptFile.sidecarPath(
            forAudioPath: track.filePath, extension: TranscriptFile.companionExtension
        ) {
            let lrc = TranscriptFile.lrc(from: segments, title: title, artist: artist)
            try await provider.upload(Data(lrc.utf8), toPath: path, contentType: "text/plain")
        }
    }

    /// Sidecars are small text files, so they're fetched whole through the provider's
    /// normal read path rather than needing one of their own.
    private static func contents(at path: String, provider: CloudProvider) async -> String? {
        guard let url = try? await provider.streamURL(forFileID: path) else { return nil }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
