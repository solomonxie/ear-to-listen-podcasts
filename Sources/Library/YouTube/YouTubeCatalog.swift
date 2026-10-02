import CryptoKit
import Foundation
import GRDB

/// Every YouTube episode, written to the connected bucket beside the backups
/// (`ear-to-listen-podcasts/youtube-catalog.json`): what each one is and where in the
/// bucket its files go, so files put there later — by hand or by the listener's own
/// tools — land where sync picks them up. See docs/design/youtube-catalog.md.
///
/// Written only when it changed, after edits go quiet (`AutoBackup`). Anything else the
/// listener keeps beside it is theirs; this app never reads or writes it.
enum YouTubeCatalog {
    static let fileName = "youtube-catalog.json"
    private static let shippedHashKey = "youtube.catalog.hash"

    struct Entry: Codable, Equatable {
        var episodeID: String
        var videoID: String
        var url: String
        var title: String
        var speaker: String
        var album: String
        /// Whole bucket key, the way every other file in the bucket is named:
        /// `<root>/<Speaker>/<Album>/<Title> [<videoID>].vtt`. Other languages go beside it
        /// as `… [<videoID>].<lang>.vtt`.
        var transcriptPath: String
        /// Where an audio file for the episode goes, if there is one; the episode then plays
        /// it like any other. Any audio extension works — the `[<videoID>]` is the match.
        var audioPath: String
    }

    struct Document: Codable {
        var version = 1
        var updatedAt: Date
        var videos: [Entry]
    }

    static func entries(_ tracks: [Track], speakers: [String: String], albums: [String: String], root: String?) -> [Entry] {
        tracks.compactMap { track in
            guard let videoID = track.youTubeID else { return nil }
            let filed = YouTubeEpisodes.filing(
                speaker: track.artistID.flatMap { speakers[$0] }, album: track.albumID.flatMap { albums[$0] }
            )
            let folder = (root ?? "") + safe(filed.speaker) + "/" + safe(filed.album) + "/"
            return Entry(
                episodeID: track.id, videoID: videoID, url: "https://www.youtube.com/watch?v=\(videoID)",
                title: track.title, speaker: filed.speaker, album: filed.album,
                transcriptPath: folder + safe(track.title) + " [\(videoID)].vtt",
                audioPath: folder + safe(track.title) + " [\(videoID)].mp3"
            )
        }
        .sorted { $0.videoID < $1.videoID }
    }

    /// A name as one path segment: no slashes, nothing a file system refuses, not endless.
    static func safe(_ name: String) -> String {
        let cleaned = name.map { "/\\:*?\"<>|".contains($0) || $0.isNewline ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(120)).nilIfEmpty ?? "Untitled"
    }

    /// Uploads the catalog if it differs from the last one shipped. One query, one PUT at
    /// most; nothing when no YouTube episode has ever been added.
    static func publishIfChanged(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) async {
        guard let provider = BackupService(dbQueue: dbQueue).remoteProviderForAppData() else { return }
        let tracks = (try? TrackStore(dbQueue: dbQueue).youTubeEpisodes()) ?? []
        let library = LibraryStore(dbQueue: dbQueue)
        let speakers = Dictionary(((try? library.artists()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let albums = Dictionary(((try? library.albums()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let videos = entries(tracks, speakers: speakers, albums: albums, root: provider.rootFolder)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(videos) else { return }
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let shipped = UserDefaults.standard.string(forKey: shippedHashKey)
        guard hash != shipped, !(videos.isEmpty && shipped == nil) else { return }
        guard let data = try? encoder.encode(Document(updatedAt: Date(), videos: videos)) else { return }
        do {
            try await provider.uploadAppData(data, named: fileName, contentType: "application/json")
            UserDefaults.standard.set(hash, forKey: shippedHashKey)
        } catch {
            // Tried again after the next change, or on leaving the app.
        }
    }
}
