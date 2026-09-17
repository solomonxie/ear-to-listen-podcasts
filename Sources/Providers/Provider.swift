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
    /// One directory level. Subfolders come back as whole paths, not bare names, so the
    /// caller can pass one straight back in without knowing where the provider's own root
    /// sits. Declared here, not just as an extension, so a provider that can ask its
    /// backend for exactly one level (S3 with a delimiter) is actually the one that runs —
    /// an extension-only default would be picked statically and quietly recurse.
    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile])
    func metadata(forFileID fileID: String) async throws -> CloudFile
    func streamURL(forFileID fileID: String) async throws -> URL
    func testConnection() async -> ConnectionTestResult

    /// Whether this source takes writes. Sidecar transcripts are the only thing the app
    /// ever puts back, and only where they're wanted.
    ///
    /// Declared here rather than only in the extension for the same reason
    /// `listDirectory` is: an extension-only member is dispatched statically, so a
    /// provider's own implementation would be silently skipped.
    var isWritable: Bool { get }
    func upload(_ data: Data, toPath path: String, contentType: String) async throws
}

enum CloudProviderError: LocalizedError {
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let type): return "This \(type) source is read-only, so the transcript stayed on this device."
        }
    }
}

extension CloudProvider {
    var isWritable: Bool { false }

    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        throw CloudProviderError.readOnly(type)
    }

    /// Fallback for providers with no one-level listing of their own: derive it from the
    /// recursive one.
    func listDirectory(atFolder folderID: String?) async throws -> (folders: [String], files: [CloudFile]) {
        let all = try await listFiles(inFolder: folderID)
        let prefix = folderID.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""

        var folderPaths: Set<String> = []
        var directFiles: [CloudFile] = []
        for file in all {
            guard file.path.hasPrefix(prefix) else { continue }
            let relative = String(file.path.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            if let slashIndex = relative.firstIndex(of: "/") {
                folderPaths.insert(prefix + relative[relative.startIndex..<slashIndex])
            } else {
                directFiles.append(file)
            }
        }
        return (folderPaths.sorted(), directFiles)
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
