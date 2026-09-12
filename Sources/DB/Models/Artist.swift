import GRDB

struct Artist: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "artists"

    var id: String
    var name: String
}
