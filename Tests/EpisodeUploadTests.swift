import GRDB
import XCTest
@testable import EarToListen

/// An episode picked out of Files is the one write that *is* audio, so the rules around it
/// are the interesting part: it lands in the folder being browsed, it never lands on top of
/// something already there, and the library hears about it without a whole-bucket re-listing.
private final class WritableBucket: CloudProvider, @unchecked Sendable {
    let type = "test-bucket"
    let rootFolder: String?
    var keys: Set<String>
    var writes: [(path: String, bytes: Int)] = []
    let isWritable: Bool

    init(rootFolder: String? = nil, keys: Set<String> = [], isWritable: Bool = true) {
        self.rootFolder = rootFolder
        self.keys = keys
        self.isWritable = isWritable
    }

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        keys.sorted().map { CloudFile(id: $0, name: ($0 as NSString).lastPathComponent, path: $0) }
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        guard keys.contains(fileID) else { throw CloudProviderError.missingFile(fileID) }
        return CloudFile(id: fileID, name: (fileID as NSString).lastPathComponent, path: fileID)
    }

    func streamURL(forFileID fileID: String) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func testConnection() async -> ConnectionTestResult { ConnectionTestResult(isSuccess: true, message: nil) }

    func write(_ data: Data, toPath path: String, contentType: String) async throws {
        writes.append((path, data.count))
        keys.insert(path)
    }
}

final class EpisodeUploadTests: XCTestCase {
    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func pick(_ name: String, bytes: Int = 8) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    private func upload(
        _ urls: [URL], to bucket: WritableBucket, folder: String?, avoiding taken: Set<String> = [],
        dbQueue: DatabaseQueue
    ) async -> EpisodeUpload.Outcome {
        await EpisodeUpload(
            provider: bucket, providerID: "p1", folder: folder, jobStore: SyncJobStore(dbQueue: dbQueue)
        ).run(urls, avoiding: taken)
    }

    func testAnEpisodeLandsInTheFolderBeingBrowsedAndIsQueued() async throws {
        let dbQueue = try makeDatabase()
        let bucket = WritableBucket(rootFolder: "podcasts/")
        let outcome = await upload([try pick("ep-01.mp3")], to: bucket, folder: "podcasts/2026/", dbQueue: dbQueue)

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(bucket.writes.map(\.path), ["podcasts/2026/ep-01.mp3"])
        let jobs = try SyncJobStore(dbQueue: dbQueue).page(limit: 10)
        XCTAssertEqual(jobs.map(\.filePath), ["podcasts/2026/ep-01.mp3"])
    }

    /// No folder open means the level the connection itself starts at, not the bucket root.
    func testWithNoFolderOpenItLandsAtTheConnectionsOwnRoot() async throws {
        let dbQueue = try makeDatabase()
        let bucket = WritableBucket(rootFolder: "podcasts/")
        _ = await upload([try pick("ep-01.mp3")], to: bucket, folder: nil, dbQueue: dbQueue)

        XCTAssertEqual(bucket.writes.map(\.path), ["podcasts/ep-01.mp3"])
    }

    /// Two episodes with the same filename are two episodes. Renaming the newcomer is the
    /// only way to keep both without touching the one already in the bucket.
    func testANameAlreadyInTheFolderIsRenamedRatherThanOverwritten() async throws {
        let dbQueue = try makeDatabase()
        let bucket = WritableBucket(keys: ["ep-01.mp3"])
        _ = await upload([try pick("ep-01.mp3")], to: bucket, folder: nil, avoiding: ["ep-01.mp3"], dbQueue: dbQueue)

        XCTAssertEqual(bucket.writes.map(\.path), ["ep-01 2.mp3"])
    }

    /// The listing the caller dodged can be stale — someone else's upload, another device.
    /// The provider checks the key itself, so "never over an episode" survives that.
    func testAKeyTheListingDidntShowIsStillRefused() async throws {
        let dbQueue = try makeDatabase()
        let bucket = WritableBucket(keys: ["ep-01.mp3"])
        let outcome = await upload([try pick("ep-01.mp3")], to: bucket, folder: nil, dbQueue: dbQueue)

        XCTAssertEqual(bucket.writes.count, 0)
        XCTAssertEqual(outcome.uploaded, [])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(try SyncJobStore(dbQueue: dbQueue).counts().total, 0)
    }

    func testAReadOnlySourceIsReportedRatherThanWrittenTo() async throws {
        let dbQueue = try makeDatabase()
        let bucket = WritableBucket(isWritable: false)
        let outcome = await upload([try pick("ep-01.mp3")], to: bucket, folder: nil, dbQueue: dbQueue)

        XCTAssertEqual(bucket.writes.count, 0)
        XCTAssertEqual(outcome.failures.count, 1)
    }
}
