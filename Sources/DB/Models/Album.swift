import Foundation
import GRDB

struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "albums"

    var id: String
    var artistID: String?
    var name: String
    /// Free text about the collection — hand-written or an accepted AI suggestion. A
    /// sentence or two; the longer read is `profile`.
    var notes: String? = nil
    /// The long read — what this collection is, who it's by, what it covers. Written by
    /// `AlbumProfileSuggester` from what the library already knows, and editable after.
    var profile: String? = nil
    /// Filename under `ImageFileStore.artwork`, not a full path.
    var artworkFileName: String? = nil
    /// When the collection is from. Episodes with no year of their own read this one —
    /// see `EpisodeDetailsPane` — so it only has to be typed once per album.
    var year: Int? = nil
    /// BCP-47 identifier for the language this album is recorded in, overriding whatever
    /// its speaker is set to — one speaker's albums aren't all in one language. Nil means
    /// "whatever the speaker says".
    var language: String? = nil
    /// Set when someone edits the album header, or applies a batch suggestion.
    var metadataEditedAt: Date? = nil
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}
