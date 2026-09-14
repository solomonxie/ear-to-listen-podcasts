import Foundation
import GRDB

struct Playlist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "playlists"

    var id: String
    var name: String
    var source: String
    var createdAt: Date
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}

struct PlaylistTrack: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playlistTracks"

    var playlistID: String
    var trackID: String
    var position: Int
}
