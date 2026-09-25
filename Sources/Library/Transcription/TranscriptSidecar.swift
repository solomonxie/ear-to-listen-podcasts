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
/// is for lyrics-aware players. It happens when someone presses Upload and at no other
/// time — see `upload`.
enum TranscriptSidecar {
    /// The first sidecar that parses into something usable. Missing files are the normal
    /// case, not an error — most episodes won't have one.
    /// Reads the sidecar the last sync recorded beside this episode. Nothing to read is
    /// the normal case, not an error — most episodes won't have one.
    ///
    /// Prefers `Track.transcriptPath`, learned from the sync listing — one request rather
    /// than probing five extensions to be told "no" four times.
    ///
    /// Falls back to probing when there's no recorded path. Knowing it is an optimisation;
    /// *not* knowing it must never be read as "there is no transcript" — a track synced by
    /// a build before the column existed, or added between listings, has a nil path and a
    /// perfectly good `.vtt` sitting beside it.
    /// The recorded path if there is one, every conventional candidate if there isn't.
    static func pathsToTry(for track: Track) -> [String] {
        if let known = track.transcriptPath?.nilIfEmpty { return [known] }
        return TranscriptFile.candidatePaths(forAudioPath: track.filePath)
    }

    static func load(track: Track, provider: CloudProvider, duration: Double?) async -> [TranscriptSegment]? {
        for path in pathsToTry(for: track) {
            guard let text = await contents(at: path, provider: provider) else { continue }
            let segments = TranscriptFile.parse(
                text, extension: (path as NSString).pathExtension, duration: duration
            )
            if !segments.isEmpty { return segments }
        }
        return nil
    }

    /// Writes the transcript over what's beside one copy of the audio, and says which
    /// files it wrote.
    ///
    /// **Only ever by hand.** Nothing in the app calls this on a change: correcting a
    /// line, joining two, running a fresh pass — all of it stays in this device's database
    /// until the Upload button is pressed. A transcript in someone's own storage is a file
    /// they may have written, edited or shared, and overwriting it as a side effect of
    /// tidying one line here is not a trade worth making silently.
    ///
    /// **Everything that is there, replaced.** The `.vtt` and its `.lrc` companion always
    /// go up. Any other transcript format already sitting beside the audio — `.srt`,
    /// `.json`, `.txt` — is rewritten too, because the point of pressing the button is
    /// that what's in the bucket now says what this app says. Formats that aren't there
    /// aren't created.
    ///
    /// Throws only on a write that was attempted and failed — a read-only source is a
    /// normal answer, not a problem to report.
    @discardableResult
    static func upload(
        _ segments: [TranscriptSegment], beside audioPath: String, provider: CloudProvider,
        title: String?, artist: String?
    ) async throws -> [String] {
        guard provider.isWritable else { return [] }
        guard segments.contains(where: { !$0.text.isEmpty }) else { return [] }

        var written: [String] = []
        for ext in TranscriptFile.writableExtensions {
            guard let path = TranscriptFile.sidecarPath(forAudioPath: audioPath, extension: ext) else { continue }
            let isOurs = ext == TranscriptFile.canonicalExtension || ext == TranscriptFile.companionExtension
            // One HEAD per extra format, on a button press, for one episode — the rule
            // against per-item probing is about listings of thousands, not this.
            if !isOurs, (try? await provider.metadata(forFileID: path)) == nil { continue }
            let text = TranscriptFile.text(from: segments, extension: ext, title: title, artist: artist)
            try await provider.upload(
                Data(text.utf8), toPath: path, contentType: TranscriptFile.contentType(for: ext)
            )
            written.append(path)
        }
        return written
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
