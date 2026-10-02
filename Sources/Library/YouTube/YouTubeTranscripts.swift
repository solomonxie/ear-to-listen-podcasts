import Foundation
import GRDB

/// Transcript files anywhere in a bucket named for a YouTube video —
/// `dQw4w9WgXcQ-title.vtt`, `dQw4w9WgXcQ-title.zh-Hans.vtt` — taken in by the YouTube
/// episode they name. A video-only episode has no audio for them to sit beside, so the ID
/// in the name is the whole match (see `YouTubeCatalog` for where they're expected).
///
/// From the listing a sync already made, matched in memory; a file is only downloaded
/// for an episode that has no transcript yet.
enum YouTubeTranscripts {
    private static let formats = ["vtt", "srt", "lrc", "json", "txt"]

    /// Video ID → transcript paths, preferred first: the untagged file, then `.vtt`.
    static func byVideoID(in listing: [CloudFile]) -> [String: [String]] {
        var found: [String: [String]] = [:]
        for file in listing {
            guard formats.contains((file.path as NSString).pathExtension.lowercased()),
                  let id = YouTubeVideo.id(inFileName: file.path) else { continue }
            found[id, default: []].append(file.path)
        }
        return found.mapValues { paths in
            paths.sorted { rank($0) < rank($1) }
        }
    }

    /// Slugs have no dots, so a dot before the extension starts a language tag.
    private static func rank(_ path: String) -> (Int, Int, String) {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let tagged = stem.contains(".") ? 1 : 0
        let format = formats.firstIndex(of: (path as NSString).pathExtension.lowercased()) ?? 9
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
