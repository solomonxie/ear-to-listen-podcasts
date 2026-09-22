import Foundation

enum LocalFilesProviderError: Error, LocalizedError, Equatable {
    case missingBookmark
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .missingBookmark: return "This local folder is missing its saved location — remove and re-add it."
        case .accessDenied: return "Couldn't access this folder. It may have been moved or deleted."
        }
    }
}

/// One episode the listener picked out of Files, and the path it's filed under here.
/// The path is what `tracks` keys off, so it has to stay put even when two picks share a
/// filename — see `LocalFileEntry.uniquePath`.
struct LocalFileEntry: Codable, Equatable {
    var path: String
    var bookmark: String

    static let settingsKey = "files"

    static func uniquePath(for name: String, avoiding taken: Set<String>) -> String {
        CloudWrite.availableName(for: name, avoiding: taken)
    }
}

/// Reads episodes straight out of Files, in place — nothing is copied into the app's own
/// storage. Either a whole folder the listener picked, or the individual episodes they
/// picked; both persist across launches as security-scoped bookmarks stored alongside the
/// other provider settings.
struct LocalFilesProvider: CloudProvider {
    static let providerType = "local"
    let type = LocalFilesProvider.providerType

    private enum Source {
        case folder(URL)
        /// Keyed by the path each file is filed under, since there's no shared root to
        /// derive one from.
        case files([String: URL])
    }

    private let source: Source

    init(config: CloudProviderConfig) throws {
        if let entries = LocalFilesProvider.entries(in: config.settings) {
            let resolved = entries.compactMap { entry -> (String, URL)? in
                guard let url = try? LocalFilesProvider.resolve(entry.bookmark) else { return nil }
                return (entry.path, url)
            }
            guard !resolved.isEmpty else { throw LocalFilesProviderError.accessDenied }
            source = .files(Dictionary(resolved, uniquingKeysWith: { first, _ in first }))
            return
        }
        guard let encoded = config.settings["bookmark"] else {
            throw LocalFilesProviderError.missingBookmark
        }
        source = .folder(try LocalFilesProvider.resolve(encoded))
    }

    static func entries(in settings: [String: String]) -> [LocalFileEntry]? {
        guard let encoded = settings[LocalFileEntry.settingsKey],
              let data = Data(base64Encoded: encoded),
              let entries = try? JSONDecoder().decode([LocalFileEntry].self, from: data)
        else { return nil }
        return entries
    }

    static func encode(_ entries: [LocalFileEntry]) throws -> String {
        try JSONEncoder().encode(entries).base64EncodedString()
    }

    private static func resolve(_ encodedBookmark: String) throws -> URL {
        guard let bookmarkData = Data(base64Encoded: encodedBookmark) else {
            throw LocalFilesProviderError.missingBookmark
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw LocalFilesProviderError.accessDenied
        }
        return url
    }

    /// A picked-files source has no folders, so a path always resolves to one bookmark.
    private func url(forPath path: String) throws -> URL {
        switch source {
        case .folder(let baseURL): return baseURL.appendingPathComponent(path)
        case .files(let urls):
            guard let url = urls[path] else { throw LocalFilesProviderError.accessDenied }
            return url
        }
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        guard case .folder(let baseURL) = source else {
            return try listPickedFiles()
        }
        let root = folderID.map { baseURL.appendingPathComponent($0) } ?? baseURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else {
            return []
        }

        var files: [CloudFile] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(baseURL.path.count + 1))
            files.append(CloudFile(
                id: relativePath,
                name: url.lastPathComponent,
                path: relativePath,
                sizeBytes: values.fileSize.map(Int64.init),
                mimeType: nil,
                modifiedAt: values.contentModificationDate
            ))
        }
        return files
    }

    /// A file that's been moved or deleted since it was picked drops out of the listing,
    /// which is how `SyncEngine` learns to mark it missing.
    private func listPickedFiles() throws -> [CloudFile] {
        guard case .files(let urls) = source else { return [] }
        return urls.compactMap { path, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return CloudFile(
                id: path,
                name: url.lastPathComponent,
                path: path,
                sizeBytes: values.fileSize.map(Int64.init),
                mimeType: nil,
                modifiedAt: values.contentModificationDate
            )
        }
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let url = try url(forPath: fileID)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return CloudFile(
            id: fileID,
            name: url.lastPathComponent,
            path: fileID,
            sizeBytes: values.fileSize.map(Int64.init),
            mimeType: nil,
            modifiedAt: values.contentModificationDate
        )
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        try url(forPath: fileID)
    }

    /// Picked files are individual grants, not a folder — there's nowhere to put a
    /// sidecar transcript, so that source stays read-only.
    var isWritable: Bool {
        if case .folder = source { return true }
        return false
    }

    func write(_ data: Data, toPath path: String, contentType: String) async throws {
        guard case .folder(let baseURL) = source else {
            throw CloudProviderError.readOnly(type)
        }
        let url = baseURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func testConnection() async -> ConnectionTestResult {
        switch source {
        case .folder(let baseURL):
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                return ConnectionTestResult(isSuccess: false, message: "Folder not found.")
            }
            return ConnectionTestResult(isSuccess: true, message: nil)
        case .files(let urls):
            let reachable = urls.values.filter { FileManager.default.fileExists(atPath: $0.path) }.count
            guard reachable > 0 else {
                return ConnectionTestResult(isSuccess: false, message: "None of these files are where they were.")
            }
            return ConnectionTestResult(isSuccess: true, message: "\(reachable) of \(urls.count) files found.")
        }
    }
}
