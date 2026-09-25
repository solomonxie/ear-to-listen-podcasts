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

    func invalidateAll() {
        lock.withLock { cache.removeAll() }
    }

    func settings(for providerID: String) -> [String: String]? {
        try? credentials.getJSON([String: String].self, forKey: Self.settingsKey(providerID: providerID))
    }

    /// Raw settings dict (bucket/keyPrefix plus whatever that cloud calls its credential)
    /// — lets the "add connection" screen offer an existing connection as a fillable
    /// draft. `nil` for a source that isn't a bucket at all.
    func bucketSettings(for record: ProviderRecord) -> [String: String]? {
        guard record.cloudKind != nil else { return nil }
        return settings(for: record.id)
    }

    /// Where this connection starts inside its bucket. A live listing gets this from the
    /// provider itself; the local fallback and the stats work in whole keys, so they need
    /// it spelled out without one.
    func rootFolder(for record: ProviderRecord) -> String? {
        CloudFolderPath.normalized(bucketSettings(for: record)?["keyPrefix"])
    }

    /// "s3://bucket/folder/" — and `cos://`, `oss://`, `az://`, `gs://`, each cloud's own
    /// shorthand. Lets two connections into the same bucket (different folders) be told
    /// apart in a list. A folder on this device gets the same treatment under `files://`,
    /// with enough of the path to tell two folders of the same name apart.
    func displayPath(for record: ProviderRecord) -> String? {
        if record.type == LocalFilesProvider.providerType {
            guard let path = settings(for: record.id)?[LocalFilesProvider.folderPathKey],
                  !path.isEmpty else { return nil }
            let parts = (path as NSString).pathComponents.filter { $0 != "/" }
            return "files://" + parts.suffix(2).joined(separator: "/")
        }
        guard let kind = record.cloudKind,
              let bucket = bucketSettings(for: record)?["bucket"], !bucket.isEmpty else { return nil }
        let folder = rootFolder(for: record)
        return folder.map { "\(kind.uriScheme)://\(bucket)/\($0)" } ?? "\(kind.uriScheme)://\(bucket)"
    }

    /// "s3://bucket/podcasts/ep1.mp3" — the whole address of one file, the way that
    /// cloud's own tooling writes it. `displayPath` says where a connection starts; this
    /// says where a file is, which is what an episode has to show once the same episode
    /// can be in more than one place.
    func fileURI(for record: ProviderRecord, filePath: String) -> String? {
        if record.type == LocalFilesProvider.providerType {
            return "files://\(filePath)"
        }
        guard let kind = record.cloudKind,
              let bucket = bucketSettings(for: record)?["bucket"], !bucket.isEmpty else { return nil }
        return "\(kind.uriScheme)://\(bucket)/\(filePath)"
    }
}
