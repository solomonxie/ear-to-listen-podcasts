import Foundation

/// Portable, secrets-free snapshot of a user's app data for manual export/import
/// and remote backup/restore. Covers playlists and the provider/import-source
/// list; excludes track/library rows (rebuilt by `SyncEngine`) and credentials
/// (stay in Keychain — re-enter them after restoring on a new device).
struct LibrarySnapshot: Codable {
    static let currentVersion = 1

    /// Identifies a track by (providerID, filePath) rather than its local DB id,
    /// since that id is a fresh UUID per device/install — stable across a resync,
    /// not across a fresh one.
    struct TrackRef: Codable {
        var providerID: String
        var filePath: String
        var title: String
        var position: Int
    }

    struct PlaylistEntry: Codable {
        var id: String
        var name: String
        var source: String
        var createdAt: Date
        var tracks: [TrackRef]
    }

    struct ProviderEntry: Codable {
        var id: String
        var type: String
        var label: String
        var isActive: Bool
        var syncFrequencyMinutes: Int?
        var createdAt: Date
    }

    struct ImportSourceEntry: Codable {
        var id: String
        var type: String
        var label: String
        var createdAt: Date
    }

    var version: Int = currentVersion
    var exportedAt: Date
    var playlists: [PlaylistEntry]
    var providers: [ProviderEntry]
    var importSources: [ImportSourceEntry]
}
