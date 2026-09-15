import Foundation

struct CloudFile: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var sizeBytes: Int64?
    var mimeType: String?
    var modifiedAt: Date?
    /// Provider-supplied content fingerprint (e.g. S3's ETag) — cheap to read from a
    /// listing/head request, so it can flag an overwritten-in-place file without a
    /// download. Providers that don't offer one leave this nil.
    var contentHash: String? = nil
}

struct ConnectionTestResult {
    var isSuccess: Bool
    var message: String?
}

struct CloudProviderConfig: Codable {
    var id: String
    var type: String
    var label: String
    var settings: [String: String]
}

protocol CloudProvider: Sendable {
    var type: String { get }
    func listFiles(inFolder folderID: String?) async throws -> [CloudFile]
    func metadata(forFileID fileID: String) async throws -> CloudFile
    func streamURL(forFileID fileID: String) async throws -> URL
    func testConnection() async -> ConnectionTestResult
}

extension CloudProvider {
    /// One directory level: immediate subfolder names and files directly in `folderID`.
    /// Derived from `listFiles`'s recursive listing since providers don't expose a
    /// delimiter-aware listing of their own.
    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let all = try await listFiles(inFolder: folderID)
        let prefix = folderID.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""

        var folderNames: Set<String> = []
        var directFiles: [CloudFile] = []
        for file in all {
            guard file.path.hasPrefix(prefix) else { continue }
            let relative = String(file.path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            if let slashIndex = relative.firstIndex(of: "/") {
                folderNames.insert(String(relative[relative.startIndex..<slashIndex]))
            } else {
                directFiles.append(file)
            }
        }
        return (folderNames.sorted(), directFiles)
    }
}

final class CloudProviderRegistry: @unchecked Sendable {
    static let shared = CloudProviderRegistry()

    private let lock = NSLock()
    private var factories: [String: (CloudProviderConfig) throws -> CloudProvider] = [:]

    func register(type: String, factory: @escaping (CloudProviderConfig) throws -> CloudProvider) {
        lock.withLock { factories[type] = factory }
    }

    func makeProvider(for config: CloudProviderConfig) throws -> CloudProvider? {
        let factory = lock.withLock { factories[config.type] }
        return try factory?(config)
    }

    var registeredTypes: [String] { lock.withLock { Array(factories.keys) } }
}
