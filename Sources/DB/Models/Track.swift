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
    var sizeBytes: Int64? = nil
    /// True when the last sync no longer found this file in the bucket listing.
    var isLost: Bool = false
    var updatedAt: Date
    /// Playback progress, in milliseconds, as of `lastPlayedAt`.
    var positionMs: Int? = nil
    var lastPlayedAt: Date? = nil
}
