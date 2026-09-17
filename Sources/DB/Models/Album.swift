import Foundation
import GRDB

struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "albums"

    var id: String
    var artistID: String?
    var name: String
    /// Free text about the collection — hand-written or an accepted AI suggestion.
    var notes: String? = nil
    /// Filename under `ImageFileStore.artwork`, not a full path.
    var artworkFileName: String? = nil
    /// Set when someone saves `AlbumEditView`, or applies a batch suggestion.
    var metadataEditedAt: Date? = nil
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}
