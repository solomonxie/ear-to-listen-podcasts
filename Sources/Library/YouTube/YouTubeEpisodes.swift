import Foundation

/// Making a YouTube video into an episode — from the Add sheet, or from a link shared in
/// from the YouTube app.
@MainActor
enum YouTubeEpisodes {
    private static var trackStore: TrackStore { TrackStore(dbQueue: DatabaseManager.shared.dbQueue) }
    private static var libraryStore: LibraryStore { LibraryStore(dbQueue: DatabaseManager.shared.dbQueue) }

    /// Who a video is filed under when nobody's said: its channel, or this.
    nonisolated static let fallbackSpeaker = "YouTube"

    nonisolated static func defaultAlbumName(for speaker: String) -> String {
        String(localized: "\(speaker)'s YouTube Podcasts")
    }

    /// A YouTube episode always sits in exactly one album, and that album is its
    /// speaker's. Blank fields fall back to the channel and to the speaker's default album.
    nonisolated static func filing(speaker: String?, album: String?) -> (speaker: String, album: String) {
        let speaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallbackSpeaker
        let album = album?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? defaultAlbumName(for: speaker)
        return (speaker, album)
    }

    static func existing(_ videoID: String) -> Track? {
        try? trackStore.find(youTubeVideoID: videoID)
    }

    @discardableResult
    static func add(
        _ videoID: String, title: String, speaker: String?, album: String? = nil,
        durationMs: Int? = nil, notes: String? = nil
    ) async throws -> Track {
        var artworkFileName: String?
        if let data = await YouTubeVideo.thumbnail(id: videoID) {
            artworkFileName = try? await ImageFileStore.artwork.save(data, maxDimension: 800)
        }
        let filed = filing(speaker: speaker, album: album)
        let artist = try libraryStore.upsertArtist(name: filed.speaker)
        let collection = try libraryStore.upsertAlbum(name: filed.album, artistID: artist.id)
        var track = Track(
            id: UUID().uuidString, providerID: YouTubeVideo.providerID,
            artistID: artist.id, albumID: collection.id, filePath: videoID, title: title,
            durationMs: durationMs, updatedAt: Date()
        )
        track.youTubeVideoID = videoID
        track.notes = notes
        track.artworkFileName = artworkFileName
        track.metadataEditedAt = Date()
        do {
            try trackStore.saveEdit(track, artistName: artist.name, albumName: collection.name)
        } catch {
            ImageFileStore.artwork.remove(artworkFileName)
            throw error
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return track
    }
}
