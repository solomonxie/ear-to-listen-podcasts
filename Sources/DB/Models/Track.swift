import Foundation
import GRDB

struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "tracks"

    var id: String
    var providerID: String
    var artistID: String?
    var albumID: String?
    var filePath: String
    var title: String
    var trackNumber: Int?
    var durationMs: Int?
    var updatedAt: Date
}
