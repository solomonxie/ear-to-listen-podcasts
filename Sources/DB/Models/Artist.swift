import GRDB

/// A "Speaker" in the UI — real synced tracks read this from embedded artist metadata.
struct Artist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "artists"

    var id: String
    var name: String
    var bio: String?
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}
