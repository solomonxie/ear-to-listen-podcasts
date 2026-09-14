import GRDB

struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "albums"

    var id: String
    var artistID: String?
    var name: String
    /// Seeded by `DemoDataSeeder`, wiped/reseeded together rather than treated as real data.
    var isDemo: Bool = false
}
