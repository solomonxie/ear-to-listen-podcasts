import GRDB

struct Album: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "albums"

    var id: String
    var artistID: String?
    var name: String
}
