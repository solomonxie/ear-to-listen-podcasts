import Foundation
import GRDB

/// Transcript files anywhere in a bucket named with a YouTube video's ID —
/// `… [dQw4w9WgXcQ].vtt`, `… [dQw4w9WgXcQ].zh-Hans.vtt` — taken in by the YouTube
/// episode they name. There's no audio for them to sit beside, so the ID in the name is
/// the whole match. Where they come from is up to the listener (see `YouTubeCatalog`).
///
/// From the listing a sync already made, matched in memory; a file is only downloaded
/// for an episode that has no transcript yet.
enum YouTubeTranscripts {
    nonisolated(unsafe) private static let named = /\[([A-Za-z0-9_-]{11})\](\.[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]+)*)?\.(vtt|srt|lrc|json|txt)$/

    /// Video ID → transcript paths, preferred first: the untagged file, then `.vtt`.
    static func byVideoID(in listing: [CloudFile]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for file in listing {
            guard let match = file.path.firstMatch(of: named) else { continue }
            found[String(match.1), default: []].append(file.path)
        }
        return found.mapValues { paths in
            paths.sorted { rank($0) < rank($1) }
        }
    }

    private static func rank(_ path: String) -> (Int, Int, String) {
        let match = path.firstMatch(of: named)
        let tagged = match?.2 == nil ? 0 : 1
        let format = ["vtt", "srt", "lrc", "json", "txt"].firstIndex(of: String(match?.3 ?? "")) ?? 9
        return (tagged, format, path)
    }

    static func adopt(_ listing: [CloudFile], provider: CloudProvider, dbQueue: DatabaseQueue) async {
        let files = byVideoID(in: listing)
        guard !files.isEmpty else { return }
        let transcripts = TranscriptStore(dbQueue: dbQueue)
        let have = (try? transcripts.transcribedTrackIDs()) ?? []
        let waiting = ((try? TrackStore(dbQueue: dbQueue).youTubeEpisodes()) ?? []).filter { !have.contains($0.id) }
        for track in waiting {
            guard let videoID = track.youTubeID, let paths = files[videoID] else { continue }
            for path in paths {
                guard let data = try? await provider.download(fileID: path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let segments = TranscriptRunner.segments(
                    in: text, extension: (path as NSString).pathExtension,
                    duration: track.durationMs.map { Double($0) / 1000 } ?? 0
                )
                guard !segments.isEmpty else { continue }
                try? transcripts.save(trackID: track.id, segments: segments, engine: TranscriptRunner.sidecarEngine)
                break
            }
        }
    }
}
