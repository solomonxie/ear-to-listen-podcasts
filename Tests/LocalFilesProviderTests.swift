import XCTest
@testable import EarToListen

final class LocalFilesProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeProvider() throws -> LocalFilesProvider {
        let bookmark = try tempDir.bookmarkData()
        let config = CloudProviderConfig(
            id: "test", type: LocalFilesProvider.providerType, label: "Test",
            settings: ["bookmark": bookmark.base64EncodedString()]
        )
        return try LocalFilesProvider(config: config)
    }

    func testMissingBookmarkThrows() {
        let config = CloudProviderConfig(id: "test", type: LocalFilesProvider.providerType, label: "Test", settings: [:])
        XCTAssertThrowsError(try LocalFilesProvider(config: config)) { error in
            XCTAssertEqual(error as? LocalFilesProviderError, .missingBookmark)
        }
    }

    func testListFilesFindsFilesInFolder() async throws {
        try Data().write(to: tempDir.appendingPathComponent("episode.mp3"))
        let provider = try makeProvider()

        let files = try await provider.listFiles(inFolder: nil)

        XCTAssertEqual(files.map(\.path), ["episode.mp3"])
    }

    /// Episodes picked one by one have no shared folder to derive a path from, so each
    /// carries its own — and two picks that happen to share a filename mustn't collapse
    /// into one track.
    func testPickedFilesAreListedUnderDistinctPaths() async throws {
        let nested = tempDir.appendingPathComponent("more")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = tempDir.appendingPathComponent("episode.mp3")
        let second = nested.appendingPathComponent("episode.mp3")
        try Data("a".utf8).write(to: first)
        try Data("bb".utf8).write(to: second)

        var entries: [LocalFileEntry] = []
        for url in [first, second] {
            let path = LocalFileEntry.uniquePath(for: url.lastPathComponent, avoiding: Set(entries.map(\.path)))
            entries.append(LocalFileEntry(path: path, bookmark: try url.bookmarkData().base64EncodedString()))
        }
        let provider = try LocalFilesProvider(config: CloudProviderConfig(
            id: "test", type: LocalFilesProvider.providerType, label: "Files",
            settings: [LocalFileEntry.settingsKey: try LocalFilesProvider.encode(entries)]
        ))

        let files = try await provider.listFiles(inFolder: nil)
        XCTAssertEqual(files.map(\.path).sorted(), ["episode 2.mp3", "episode.mp3"])
        let streamed = try await provider.streamURL(forFileID: "episode.mp3")
        XCTAssertEqual(streamed.lastPathComponent, "episode.mp3")
        // No folder to put a sidecar transcript in.
        XCTAssertFalse(provider.isWritable)
    }

    func testTestConnectionSucceedsForExistingFolder() async throws {
        let provider = try makeProvider()
        let result = await provider.testConnection()
        XCTAssertTrue(result.isSuccess)
    }
}
