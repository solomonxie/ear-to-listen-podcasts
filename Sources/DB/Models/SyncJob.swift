import Foundation
import GRDB

enum SyncJobStatus: String, Codable {
    case pending, running, done, failed
}

/// What a running job is actually doing. "Waiting" and a spinner say a file is being
/// worked but not what's taking the time — a slow tag read and a slow AI call look
/// identical without this.
enum SyncJobStage: String, Codable {
    case queued
    case readingTags
    case askingAI
    case saving

    var displayName: String {
        switch self {
        case .queued: return "Waiting"
        case .readingTags: return "Reading tags"
        case .askingAI: return "Asking AI"
        case .saving: return "Saving to library"
        }
    }
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
    /// The transcript sitting beside this file in the listing, if there was one.
    var transcriptPath: String?
    var status: SyncJobStatus
    var stage: SyncJobStage?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}
