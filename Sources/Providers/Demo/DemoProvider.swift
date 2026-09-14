import Foundation

/// Reads the bundled sample clips under `Resources/DemoAudio` — backs the seeded demo
/// library (`DemoDataSeeder`) so it plays through the exact same `PlaybackEngine` path
/// as a real synced track, rather than a separate mock player.
struct DemoProvider: CloudProvider {
    static let providerType = "demo"
    let type = DemoProvider.providerType

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
        // `Resources/DemoAudio` is a flattened group, not a folder reference, so its
        // contents land at the bundle root, not under a "DemoAudio/" path.
        guard let url = Bundle.main.url(forResource: fileID, withExtension: "m4a") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    func testConnection() async -> ConnectionTestResult {
        ConnectionTestResult(isSuccess: true, message: nil)
    }

    /// File names double as their `CloudFile.path`/`Track.filePath` — matches how
    /// `DemoDataSeeder` references them when creating tracks.
    static let files: [CloudFile] = [
        CloudFile(id: "ep-tech-1", name: "ep-tech-1.m4a", path: "ep-tech-1", sizeBytes: nil, mimeType: "audio/m4a", modifiedAt: nil),
        CloudFile(id: "ep-history-1", name: "ep-history-1.m4a", path: "ep-history-1", sizeBytes: nil, mimeType: "audio/m4a", modifiedAt: nil),
        CloudFile(id: "ep-news-1", name: "ep-news-1.m4a", path: "ep-news-1", sizeBytes: nil, mimeType: "audio/m4a", modifiedAt: nil),
    ]
}
