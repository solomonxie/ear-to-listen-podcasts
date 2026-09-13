import Foundation

/// Reads episodes straight out of the app's on-device Documents/Music folder.
/// Files land there via the Files app ("On My iPhone" > Bring Your Own Podcasts > Music)
/// or Finder file sharing over USB — no credentials, no network.
struct LocalFilesProvider: CloudProvider {
    static let providerType = "local"
    let type = LocalFilesProvider.providerType

    private let baseURL: URL

    init(config: CloudProviderConfig) throws {
        baseURL = Self.musicDirectory
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    static var musicDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Music", isDirectory: true)
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

    func testConnection() async -> ConnectionTestResult {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return ConnectionTestResult(isSuccess: false, message: "Music folder not found.")
        }
        return ConnectionTestResult(isSuccess: true, message: nil)
    }
}
