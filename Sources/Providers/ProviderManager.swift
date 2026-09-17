import Foundation

enum ProviderManagerError: Error {
    case unknownType(String)
}

/// Resolves a `ProviderRecord` (DB metadata) into a live `CloudProvider`, reading
/// its secret settings from Keychain rather than the DB. Caches instances so
/// repeated playback/sync calls don't reconnect every time.
final class ProviderManager: @unchecked Sendable {
    static let shared = ProviderManager()

    private let lock = NSLock()
    private var cache: [String: CloudProvider] = [:]
    private let credentials = CredentialStore()

    static func settingsKey(providerID: String) -> String { "provider.\(providerID).settings" }

    func saveSettings(_ settings: [String: String], forProviderID providerID: String) throws {
        try credentials.setJSON(settings, forKey: Self.settingsKey(providerID: providerID))
    }

    func deleteSettings(forProviderID providerID: String) throws {
        try credentials.delete(Self.settingsKey(providerID: providerID))
        invalidate(providerID: providerID)
    }

    func provider(for record: ProviderRecord) throws -> CloudProvider {
        if let cached = lock.withLock({ cache[record.id] }) {
            return cached
        }
        let settings = try credentials.getJSON([String: String].self, forKey: Self.settingsKey(providerID: record.id)) ?? [:]
        let config = CloudProviderConfig(id: record.id, type: record.type, label: record.label, settings: settings)
        guard let provider = try CloudProviderRegistry.shared.makeProvider(for: config) else {
            throw ProviderManagerError.unknownType(record.type)
        }
        lock.withLock { cache[record.id] = provider }
        return provider
    }

    func invalidate(providerID: String) {
        lock.withLock { cache.removeValue(forKey: providerID) }
    }

    /// Raw settings dict (accessKeyId/secretAccessKey/region/bucket/keyPrefix) — lets the
    /// "add connection" screen offer an existing S3 connection as a fillable draft.
    func s3Settings(for record: ProviderRecord) -> [String: String]? {
        guard record.type == S3Provider.providerType else { return nil }
        return try? credentials.getJSON([String: String].self, forKey: Self.settingsKey(providerID: record.id))
    }

    /// "s3://bucket/folder/" for display — lets two connections to the same bucket
    /// (different folders) be told apart in a list.
    func s3DisplayPath(for record: ProviderRecord) -> String? {
        guard let settings = s3Settings(for: record), let bucket = settings["bucket"], !bucket.isEmpty else { return nil }
        let folder = S3FolderPath.normalized(settings["keyPrefix"])
        return folder.map { "s3://\(bucket)/\($0)" } ?? "s3://\(bucket)"
    }
}
