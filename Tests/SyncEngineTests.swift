import GRDB
import XCTest
@testable import EarToListen

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

    /// `SyncQueueManager.drain()` can't run here — it's main-actor and hard-wired to the
    /// app database — so this is its loop over the injected one: claim, work, repeat. It
    /// goes through the same `perform` the real drain does, so there's no test-only
    /// import path to drift away from production.
    private func drainQueue(_ engine: SyncEngine, _ record: ProviderRecord, dbQueue: DatabaseQueue) async throws {
        let store = SyncJobStore(dbQueue: dbQueue)
        while let job = try store.dequeueNextPending() {
            await engine.perform(job, providerRecord: record)
        }
    }

    func testSyncQueuesNewAudioFilesAndSkipsNonAudio() async throws {
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

        XCTAssertEqual(result.queued, 1)
        XCTAssertEqual(result.totalFiles, 1)
        XCTAssertEqual(try SyncJobStore(dbQueue: dbQueue).page(limit: 10).map(\.filePath), ["episode1.mp3"])
        XCTAssertTrue(
            try TrackStore(dbQueue: dbQueue).all().isEmpty,
            "the listing pass queues; importing is the drain loop's job"
        )
    }

    /// The other half of the pass above — and the one that still covers
    /// `importFileIfNeeded` end to end, now that `sync` no longer calls it.
    func testDrainingTheQueueImportsWhatTheSyncPassQueued() async throws {
        let dbQueue = try makeDatabase()
        let providerID = UUID().uuidString
        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil),
        ]
        let record = makeRecord(providerID: providerID)
        try ProviderStore(dbQueue: dbQueue).upsert(record)
        let engine = try makeEngine(providerID: providerID, dbQueue: dbQueue)
        _ = try await engine.sync(providerRecord: record)

        try await drainQueue(engine, record, dbQueue: dbQueue)

        let tracks = try TrackStore(dbQueue: dbQueue).all()
        XCTAssertEqual(tracks.map(\.filePath), ["episode1.mp3"])
        XCTAssertEqual(tracks.first?.title, "episode1")
        XCTAssertEqual(try SyncJobStore(dbQueue: dbQueue).page(limit: 10).first?.status, .done)
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
        try await drainQueue(engine, record, dbQueue: dbQueue)
        let second = try await engine.sync(providerRecord: record)

        XCTAssertEqual(second.queued, 0)
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
        try await drainQueue(engine, record, dbQueue: dbQueue)

        Self.fakeFileLists[providerID] = []
        let result = try await engine.sync(providerRecord: record)

        XCTAssertEqual(result.lost, 1)
        let track = try TrackStore(dbQueue: dbQueue).all().first
        XCTAssertEqual(track?.isLost, true)
    }

    /// Same path, same size, different content — the case size-only comparison can't catch.
    func testSyncDetectsInPlaceOverwriteViaContentHash() async throws {
        let dbQueue = try makeDatabase()
        let providerID = UUID().uuidString
        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil, contentHash: "hash-a"),
        ]
        let record = makeRecord(providerID: providerID)
        try ProviderStore(dbQueue: dbQueue).upsert(record)
        let engine = try makeEngine(providerID: providerID, dbQueue: dbQueue)
        _ = try await engine.sync(providerRecord: record)
        try await drainQueue(engine, record, dbQueue: dbQueue)

        Self.fakeFileLists[providerID] = [
            CloudFile(id: "episode1.mp3", name: "episode1.mp3", path: "episode1.mp3", sizeBytes: 100, mimeType: nil, modifiedAt: nil, contentHash: "hash-b"),
        ]
        let result = try await engine.sync(providerRecord: record)

        XCTAssertEqual(result.queued, 1, "a changed file goes back in the queue")
        try await drainQueue(engine, record, dbQueue: dbQueue)
        let tracks = try TrackStore(dbQueue: dbQueue).all()
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.contentHash, "hash-b")
    }
}

/// The unique index on (providerID, filePath) is the real identity of a track — two
/// importers racing on the same file each mint their own UUID, and before this the second
/// insert failed with "UNIQUE constraint failed: tracks.providerID, tracks.filePath".
final class TrackUpsertRaceTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    private func track(id: String, title: String) -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: nil, filePath: "a/ep.mp3",
            title: title, trackNumber: nil, durationMs: nil, updatedAt: Date()
        )
    }

    func testASecondImportOfTheSameFileUpdatesInPlaceInsteadOfColliding() throws {
        let store = TrackStore(dbQueue: try makeDatabase())
        try store.upsert(track(id: "first-uuid", title: "Episode"), artistName: nil, albumName: nil)

        try store.upsert(track(id: "second-uuid", title: "Episode (better title)"), artistName: nil, albumName: nil)

        let all = try store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, "first-uuid")
        XCTAssertEqual(all.first?.title, "Episode (better title)")
    }

    func testAReimportKeepsWhereTheListenerGotTo() throws {
        let store = TrackStore(dbQueue: try makeDatabase())
        try store.upsert(track(id: "first-uuid", title: "Episode"), artistName: nil, albumName: nil)
        try store.recordProgress(id: "first-uuid", positionMs: 42_000)

        try store.upsert(track(id: "second-uuid", title: "Episode"), artistName: nil, albumName: nil)

        XCTAssertEqual(try store.find(id: "first-uuid")?.positionMs, 42_000)
    }
}
