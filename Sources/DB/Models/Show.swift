import Foundation
import GRDB

/// A podcast series — one or more `Artist` hosts, tagged with `Topic`s, grouping `Track`s
/// via `Track.showID`. Distinct from `Album`, which is a curated release rather than an
/// ongoing series.
struct Show: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "shows"

    var id: String
    var name: String
    var summary: String?
    var isSaved: Bool = false
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
    var createdAt: Date
}

struct Topic: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "topics"

    var id: String
    var name: String
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}

struct ShowArtist: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "showArtists"
    var showID: String
    var artistID: String
}

struct ShowTopic: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "showTopics"
    var showID: String
    var topicID: String
}
