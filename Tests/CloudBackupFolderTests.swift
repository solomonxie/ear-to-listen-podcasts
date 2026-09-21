import XCTest
@testable import EarToListen

/// Where the library archive lands in someone's bucket, and which copy comes back — the
/// same folder for every cloud, since it's written through the protocol alone.
private final class FakeBucket: CloudProvider, @unchecked Sendable {
    let type = "test-bucket"
    let rootFolder: String?
    var files: [String]
    var uploads: [(path: String, data: Data)] = []

    init(rootFolder: String?, files: [String] = []) {
        self.rootFolder = rootFolder
        self.files = files
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        let prefix = folderID ?? ""
        return files.filter { $0.hasPrefix(prefix) }.map {
            CloudFile(id: $0, name: ($0 as NSString).lastPathComponent, path: $0)
        }
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        CloudFile(id: fileID, name: fileID, path: fileID)
    }

    func streamURL(forFileID fileID: String) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func testConnection() async -> ConnectionTestResult { ConnectionTestResult(isSuccess: true, message: nil) }

    func download(fileID: String) async throws -> Data {
        guard files.contains(fileID) else { throw CloudProviderError.missingFile(fileID) }
        return Data(fileID.utf8)
    }

    var isWritable: Bool { true }

    func upload(_ data: Data, toPath path: String, contentType: String) async throws {
        uploads.append((path, data))
        files.append(path)
    }
}

final class CloudBackupFolderTests: XCTestCase {
    func testTheArchiveIsWrittenUnderTheConnectionsOwnFolder() async throws {
        let bucket = FakeBucket(rootFolder: "podcasts/")
        try await bucket.uploadBackup(Data("archive".utf8))

        XCTAssertEqual(bucket.uploads.map(\.path), ["podcasts/ear-to-listen-podcasts/\(BackupArchiveName.current())"])
    }

    func testTheNewestArchiveIsTheOneRestored() async throws {
        let bucket = FakeBucket(rootFolder: nil, files: [
            "ear-to-listen-podcasts/20260901-ear-to-listen.zip",
            "ear-to-listen-podcasts/20260919-ear-to-listen.zip",
            "ear-to-listen-podcasts/20260405-ear-to-listen.zip",
        ])
        let restored = try await bucket.downloadBackup()

        XCTAssertEqual(restored, Data("ear-to-listen-podcasts/20260919-ear-to-listen.zip".utf8))
    }

    /// A copy written under the app's old name still restores — a rename that strands the
    /// backups is a rename that loses the library.
    func testACopyFromAnOlderBuildStillRestores() async throws {
        let bucket = FakeBucket(rootFolder: "podcasts/", files: [
            "podcasts/bring-your-own-podcasts/app-data-backup.zip",
        ])
        let restored = try await bucket.downloadBackup()

        XCTAssertEqual(restored, Data("podcasts/bring-your-own-podcasts/app-data-backup.zip".utf8))
    }

    /// Nothing backed up yet is a normal answer, not a failure.
    func testAnEmptyBucketRestoresNothing() async throws {
        let bucket = FakeBucket(rootFolder: nil, files: ["shows/ep1.mp3"])
        let restored = try await bucket.downloadBackup()

        XCTAssertNil(restored)
    }
}
