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
    /// Same fields as `CloudFile.contentHash`/`modifiedAt` — carried through so a queued
    /// refresh (not just a brand-new import) can still detect an in-place overwrite via
    /// hash rather than falling back to size alone.
    var contentHash: String?
    var remoteModifiedAt: Date?
    var status: SyncJobStatus
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}
