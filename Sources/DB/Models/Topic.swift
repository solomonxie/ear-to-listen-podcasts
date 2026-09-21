import Foundation
import GRDB

/// A subject tag on a collection — "sleep", "history", "biography".
///
/// Topics used to hang off a `Show`, which was a second grouping concept alongside
/// `Album` that nothing in a bucket of files ever actually populated. The albums are what
/// a synced library really has, so that's what a topic tags now.
struct Topic: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "topics"

    var id: String
    var name: String
    /// Only ever set by the repo-only sample seeder (`DemoData/`); nothing shipped writes it.
    var isDemo: Bool = false
}

struct AlbumTopic: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "albumTopics"
    var albumID: String
    var topicID: String
}
