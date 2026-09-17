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

/// Reads episodes straight out of a folder the user picked via the Files app,
/// in place — nothing is copied into the app's own storage. Access persists
/// across launches via a security-scoped bookmark stored alongside the other
/// provider settings.
struct LocalFilesProvider: CloudProvider {
    static let providerType = "local"
    let type = LocalFilesProvider.providerType

    private let baseURL: URL

    init(config: CloudProviderConfig) throws {
        guard
            let encoded = config.settings["bookmark"],
            let bookmarkData = Data(base64Encoded: encoded)
        else {
            throw LocalFilesProviderError.missingBookmark
        }

        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        guard url.startAccessingSecurityScopedResource() else {
            throw LocalFilesProviderError.accessDenied
        }
        baseURL = url
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
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

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        let url = baseURL.appendingPathComponent(fileID)
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
        baseURL.appendingPathComponent(fileID)
    }

    var isWritable: Bool { true }

    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func testConnection() async -> ConnectionTestResult {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return ConnectionTestResult(isSuccess: false, message: "Folder not found.")
        }
        return ConnectionTestResult(isSuccess: true, message: nil)
    }
}
