import Foundation
import GRDB

struct Playlist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "playlists"

    var id: String
    var name: String
    var source: String
    var createdAt: Date
}

struct PlaylistTrack: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlistTracks"

    var playlistID: String
    var trackID: String
    var position: Int
}
