import GRDB
import XCTest
@testable import BringYourOwnPodcasts

/// A `CloudProvider` whose file listing is set per-test via `SyncEngineTests.fakeFileLists`,
/// keyed by provider id — the registry factory closure only receives a `CloudProviderConfig`,
/// not test state directly.
private struct FakeCloudProvider: CloudProvider {
    let type = "test-fake"
    let providerID: String

    func listFiles(inFolder folderID: String?) async throws -> [CloudFile] {
        SyncEngineTests.fakeFileLists[providerID] ?? []
    }

    func metadata(forFileID fileID: String) async throws -> CloudFile {
        guard let file = SyncEngineTests.fakeFileLists[providerID]?.first(where: { $0.id == fileID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return file
    }

    /// Points at a file that exists but isn't a valid audio asset, so embedded-metadata
    /// extraction fails gracefully and sync falls back to the filename — deliberately
    /// avoids depending on a real bundled audio fixture for this test.
    func streamURL(forFileID fileID: String) async throws -> URL {
        URL(fileURLWithPath: "/dev/null")
    }

    func testConnection() async -> ConnectionTestResult {
        ConnectionTestResult(isSuccess: true, message: nil)
    }
}

final class SyncEngineTests: XCTestCase {
    /// Tests run serially and each awaits its sync calls to finish before touching this again,
    /// so there's no real concurrent access — `unsafe` just opts out of a check Swift can't
    /// otherwise verify for a plain static var.
    nonisolated(unsafe) static var fakeFileLists: [String: [CloudFile]] = [:]

    override class func setUp() {
        CloudProviderRegistry.shared.register(type: "test-fake") { config in
            FakeCloudProvider(providerID: config.id)
        }
    }

    private func makeRecord(providerID: String) -> ProviderRecord {
        ProviderRecord(id: providerID, type: "test-fake", label: "Fake", configJSON: "", isActive: true, createdAt: Date())
    }

    private func makeEngine(providerID: String, dbQueue: DatabaseQueue) throws -> SyncEngine {
        try ProviderManager.shared.saveSettings([:], forProviderID: providerID)
        addTeardownBlock { try? ProviderManager.shared.deleteSettings(forProviderID: providerID) }
        return SyncEngine(dbQueue: dbQueue)
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    func testSyncAddsNewAudioFilesAndSkipsNonAudio() async throws {
        let dbQueue = try makeDatabase()
        let providerID = UUID().uuidString
        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil),
            CloudFile(id: "cover.jpg", name: "cover.jpg", path: "cover.jpg", sizeBytes: 50, mimeType: nil, modifiedAt: nil),
        ]
        let record = makeRecord(providerID: providerID)
        try ProviderStore(dbQueue: dbQueue).upsert(record)
        let engine = try makeEngine(providerID: providerID, dbQueue: dbQueue)

        let result = try await engine.sync(providerRecord: record)

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.totalFiles, 1)
        let tracks = try TrackStore(dbQueue: dbQueue).all()
        XCTAssertEqual(tracks.map(\.filePath), ["episode1.mp3"])
        XCTAssertEqual(tracks.first?.title, "episode1")
    }

    func testSyncIsIdempotentForUnchangedFiles() async throws {
        let dbQueue = try makeDatabase()
        let providerID = UUID().uuidString
        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil),
        ]
        let record = makeRecord(providerID: providerID)
        try ProviderStore(dbQueue: dbQueue).upsert(record)
        let engine = try makeEngine(providerID: providerID, dbQueue: dbQueue)

        _ = try await engine.sync(providerRecord: record)
        let second = try await engine.sync(providerRecord: record)

        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(try TrackStore(dbQueue: dbQueue).all().count, 1)
    }

    func testSyncMarksRemovedFilesAsLost() async throws {
        let dbQueue = try makeDatabase()
        let providerID = UUID().uuidString
        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil),
        ]
        let record = makeRecord(providerID: providerID)
        try ProviderStore(dbQueue: dbQueue).upsert(record)
        let engine = try makeEngine(providerID: providerID, dbQueue: dbQueue)
        _ = try await engine.sync(providerRecord: record)

        Self.fakeFileLists[providerID] = []
        let result = try await engine.sync(providerRecord: record)

        XCTAssertEqual(result.lost, 1)
        let track = try TrackStore(dbQueue: dbQueue).all().first
        XCTAssertEqual(track?.isLost, true)
    }
}
