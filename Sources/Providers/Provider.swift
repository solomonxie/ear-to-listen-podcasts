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

    /// A setting no provider can start without. Empty counts as missing — a field left
    /// blank in the add-a-source form is the same mistake as one never filled in.
    func required(_ key: String) throws -> String {
        guard let value = settings[key], !value.isEmpty else {
            throw CloudProviderError.missingSetting(key)
        }
        return value
    }

    /// Normalized on read as well as on save, so connections stored before folders were
    /// required (a prefix with no trailing slash) start behaving like folders too.
    var folder: String? { CloudFolderPath.normalized(settings["keyPrefix"]) }

    var kind: CloudSourceKind? { CloudSourceKind(providerType: type) }
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

    /// Where this connection starts inside its bucket, `nil` for the whole of it. The app
    /// writes its own files relative to this, and the browser needs it to show the level
    /// the listener actually connected to rather than the bucket root.
    var rootFolder: String? { get }

    /// The bytes of one file. Declared here rather than only in the extension for the same
    /// reason `listDirectory` is: an extension-only member is dispatched statically, so a
    /// provider with a cheaper way of its own would be silently skipped.
    func download(fileID: String) async throws -> Data

    /// Whether this source takes writes — a sidecar transcript, a library archive, or an
    /// episode the listener uploaded, and only where they're wanted.
    ///
    /// Declared here rather than only in the extension for the same reason
    /// `listDirectory` is: an extension-only member is dispatched statically, so a
    /// provider's own implementation would be silently skipped.
    var isWritable: Bool { get }

    /// The raw put, with no rule attached — implemented per backend, called only by the
    /// two gates below. Everything else in the app uses `upload`/`uploadEpisode`, so the
    /// never-overwrite-audio rule is one piece of code rather than a habit five providers
    /// have to keep.
    func write(_ data: Data, toPath path: String, contentType: String) async throws
}

enum CloudProviderError: LocalizedError {
    case readOnly(String)
    case missingSetting(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let type): return "This \(type) source is read-only, so nothing was written to it."
        case .missingSetting(let key): return "Missing setting: \(key)"
        case .missingFile(let path): return "No file at \(path)."
        }
    }
}

/// The code the storage service actually returned — `AccessDenied`, `SignatureDoesNotMatch`,
/// `AuthenticationFailed` — rather than a generic "the operation couldn't be completed".
/// Which of those it is, is the whole content of the message for someone whose bucket
/// won't connect.
func describeCloudError(_ error: Error) -> String {
    error.localizedDescription
}

extension CloudProvider {
    var isWritable: Bool { false }

    var rootFolder: String? { nil }

    /// Good enough for every provider that can mint a signed URL: the URL is the whole
    /// credential, so fetching it needs nothing else.
    func download(fileID: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: try await streamURL(forFileID: fileID))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CloudProviderError.missingFile(fileID)
        }
        return data
    }

    func write(_ data: Data, toPath path: String, contentType: String) async throws {
        throw CloudProviderError.readOnly(type)
    }

    /// Anything the app writes by itself: a transcript sidecar, a library archive. Never
    /// an episode — see `CloudWrite`.
    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        try await write(data, toPath: try CloudWrite.checked(path), contentType: contentType)
    }

    /// An episode the listener picked out of Files. The key has to be free: the caller
    /// already dodges the names it can see in its listing, and this is what makes
    /// "never over an episode" true of a folder that changed underneath it.
    func uploadEpisode(_ data: Data, toPath path: String, contentType: String) async throws {
        let key = try CloudWrite.checkedEpisode(path)
        guard isWritable else { throw CloudProviderError.readOnly(type) }
        if (try? await metadata(forFileID: key)) != nil {
            throw CloudWrite.WouldOverwriteAudioError(path: key)
        }
        try await write(data, toPath: key, contentType: contentType)
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
