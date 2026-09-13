import Foundation
import GRDB

struct ProviderRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "providers"

    var id: String
    var type: String
    var label: String
    var configJSON: String
    var isActive: Bool
    var createdAt: Date
    /// Minutes between auto-syncs; nil means manual only ("Sync Now").
    var syncFrequencyMinutes: Int? = nil
    var lastSyncedAt: Date? = nil
}

struct ImportSourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "importSources"

    var id: String
    var type: String
    var label: String
    var createdAt: Date
}
