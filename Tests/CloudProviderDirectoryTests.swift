import XCTest
@testable import EarToListen

/// A `CloudProvider` backed by a fixed flat file list, to exercise the default
/// `listDirectory` derivation without a real provider.
private struct FakeCloudProvider: CloudProvider {
    let type = "test-fake"
    let allFiles: [CloudFile]

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        guard let folderID else { return allFiles }
        let prefix = folderID.hasSuffix("/") ? folderID : folderID + "/"
        return allFiles.filter { $0.path.hasPrefix(prefix) }
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        guard let file = allFiles.first(where: { $0.id == fileID }) else { throw CocoaError(.fileNoSuchFile) }
        return file
    }

    func streamURL(forFileID fileID: String) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func testConnection() async -> ConnectionTestResult { ConnectionTestResult(isSuccess: true, message: nil) }
}

final class CloudProviderDirectoryTests: XCTestCase {
    private func file(_ path: String) -> CloudFile {
        CloudFile(id: path, name: (path as NSString).lastPathComponent, path: path, sizeBytes: 100, mimeType: nil, modifiedAt: nil)
    }

    func testRootListingSeparatesTopLevelFoldersFromFiles() async throws {
        let provider = FakeCloudProvider(allFiles: [
            file("show-a/ep1.mp3"),
            file("show-a/ep2.mp3"),
            file("show-b/ep1.mp3"),
            file("readme.txt"),
        ])

        let listing = try await provider.listDirectory(atFolder: nil)

        XCTAssertEqual(listing.folders, ["show-a", "show-b"])
        XCTAssertEqual(listing.files.map(\.path), ["readme.txt"])
    }

    func testNestedListingIsScopedToThatFolderOnly() async throws {
        let provider = FakeCloudProvider(allFiles: [
            file("show-a/ep1.mp3"),
            file("show-a/season1/ep2.mp3"),
            file("show-b/ep1.mp3"),
        ])

        let listing = try await provider.listDirectory(atFolder: "show-a")

        // A whole path, so it can be handed straight back to `listDirectory`.
        XCTAssertEqual(listing.folders, ["show-a/season1"])
        XCTAssertEqual(listing.files.map(\.path), ["show-a/ep1.mp3"])
    }

    func testEmptyFolderReturnsNoFoldersOrFiles() async throws {
        let provider = FakeCloudProvider(allFiles: [file("show-a/ep1.mp3")])

        let listing = try await provider.listDirectory(atFolder: "show-b")

        XCTAssertTrue(listing.folders.isEmpty)
        XCTAssertTrue(listing.files.isEmpty)
    }
}
