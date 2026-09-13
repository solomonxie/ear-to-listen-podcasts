import XCTest
@testable import BringYourOwnPodcasts

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

    func testTestConnectionSucceedsForExistingFolder() async throws {
        let provider = try makeProvider()
        let result = await provider.testConnection()
        XCTAssertTrue(result.isSuccess)
    }
}
