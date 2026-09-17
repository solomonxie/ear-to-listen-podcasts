import GRDB

/// A "Speaker" in the UI — real synced tracks read this from embedded artist metadata.
struct Artist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "artists"

    var id: String
    var name: String
    var bio: String?
    /// Filename under `ImageFileStore.speakerPhotos`'s directory — not a full path, so it stays valid
    /// across reinstalls/devices and travels as-is in a `LibrarySnapshot` backup.
    var photoFileName: String?
    /// BCP-47 identifier for the language this speaker speaks, e.g. `zh-CN`. Drives which
    /// recognizer transcribes their episodes; nil falls back to the phone's language.
    var language: String?
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}
