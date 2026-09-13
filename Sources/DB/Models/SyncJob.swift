import Foundation
import GRDB

enum SyncJobStatus: String, Codable {
    case pending, running, done, failed
}

/// One file queued to be imported (or refreshed) from a provider — the unit of work
/// behind the sync queue's pause/clear/concurrency controls.
struct SyncJob: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "syncJobs"

    var id: String
    var providerID: String
    var filePath: String
    var displayName: String
    var sizeBytes: Int64?
    var status: SyncJobStatus
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}
