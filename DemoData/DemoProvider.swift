import Foundation

/// A fake S3 bucket (`podcasts-demo`) in demo mode: lists one folder per show and
/// plays the bundled sample episodes (`DemoData/Audio`, `demo-<episode>.m4a` at the bundle
/// root) through the same `PlaybackEngine` path as a real source.
struct DemoProvider: CloudProvider {
    static let providerType = "demo"
    static let providerID = "demo-bucket"
    static let bucketName = "podcasts-demo"
    let type = "s3"
    let isOnDevice = true

    static func fileName(for episodeKey: String) -> String { "demo-\(episodeKey).m4a" }

    /// The key a file sits at in the fake bucket: its show's folder, then the file.
    static func path(for episodeKey: String, album: String) -> String { "\(album)/\(fileName(for: episodeKey))" }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        let prefix = folderID.map { $0.hasSuffix("/") ? $0 : $0 + "/" } ?? ""
        return Self.files.filter { $0.path.hasPrefix(prefix) }
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        guard let file = Self.files.first(where: { $0.path == fileID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return file
    }

    func streamURL(forFileID fileID: String) async throws -> URL {
        guard let url = Bundle.main.url(forResource: (fileID as NSString).lastPathComponent, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    func testConnection() async -> ConnectionTestResult {
        ConnectionTestResult(isSuccess: true, message: nil)
    }

    private struct FolderIndex: Decodable {
        struct Album: Decodable {
            struct Episode: Decodable { var key: String }
            var name: String
            var episodes: [Episode]
        }
        var albums: [Album]
    }

    /// Episode key → show name, from the same file the seeder reads.
    private static let folders: [String: String] = {
        guard let url = Bundle.main.url(forResource: "demo-library", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(FolderIndex.self, from: data) else { return [:] }
        return Dictionary(
            index.albums.flatMap { album in album.episodes.map { ($0.key, album.name) } },
            uniquingKeysWith: { first, _ in first }
        )
    }()

    static var files: [CloudFile] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "m4a", subdirectory: nil) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("demo-") }.map { url in
            let name = url.lastPathComponent
            let key = String(name.dropFirst("demo-".count).dropLast(".m4a".count))
            let path = folders[key].map { "\($0)/\(name)" } ?? name
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return CloudFile(id: path, name: name, path: path, sizeBytes: size, mimeType: "audio/mp4", modifiedAt: nil)
        }
    }
}
