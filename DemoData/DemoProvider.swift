import Foundation

/// Plays the bundled sample episodes (`DemoData/Audio`) through the same `PlaybackEngine`
/// path as a real source. Files sit at the bundle root as `demo-<episode>.m4a`.
struct DemoProvider: CloudProvider {
    static let providerType = "demo"
    let type = DemoProvider.providerType
    let isOnDevice = true

    static func fileName(for episodeKey: String) -> String { "demo-\(episodeKey).m4a" }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        Self.files
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        guard let file = Self.files.first(where: { $0.path == fileID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return file
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        guard let url = Bundle.main.url(forResource: fileID, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    func testConnection() async -> ConnectionTestResult {
        ConnectionTestResult(isSuccess: true, message: nil)
    }

    static var files: [CloudFile] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("demo-") }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return CloudFile(
                id: url.lastPathComponent, name: url.lastPathComponent, path: url.lastPathComponent,
                sizeBytes: size, mimeType: "audio/mp4", modifiedAt: nil
            )
        }
    }
}
