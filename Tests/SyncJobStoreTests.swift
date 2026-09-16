import GRDB
import XCTest
@testable import BringYourOwnPodcasts

final class SyncJobStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        // syncJobs.providerID is a foreign key into providers.
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    /// Written directly rather than via `enqueue` so `createdAt`/`updatedAt` are controlled —
    /// several `enqueue` calls in a row can land in the same millisecond, which wouldn't
    /// pin down the order this test is about.
    private func insert(
        _ id: String, status: SyncJobStatus, createdAt: TimeInterval, updatedAt: TimeInterval,
        into dbQueue: DatabaseQueue
    ) throws {
        let job = SyncJob(
            id: id, providerID: "p1", filePath: "\(id).mp3", displayName: "\(id).mp3",
            sizeBytes: nil, contentHash: nil, remoteModifiedAt: nil, status: status, errorMessage: nil,
            createdAt: Date(timeIntervalSince1970: createdAt), updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
        try dbQueue.write { db in try job.save(db) }
    }

    func testQueuingTheSameFileTwiceReusesTheJobAlreadyInFlight() throws {
        let store = SyncJobStore(dbQueue: try makeDatabase())

        let first = try store.enqueue(providerID: "p1", filePath: "a/ep.mp3", displayName: "ep.mp3", sizeBytes: 1)
        let second = try store.enqueue(providerID: "p1", filePath: "a/ep.mp3", displayName: "ep.mp3", sizeBytes: 1)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try store.counts().total, 1)
        XCTAssertTrue(try store.hasUnfinished(providerID: "p1", filePath: "a/ep.mp3"))
    }

    func testAFinishedJobDoesNotBlockQueuingThatFileAgain() throws {
        let store = SyncJobStore(dbQueue: try makeDatabase())
        let first = try store.enqueue(providerID: "p1", filePath: "a/ep.mp3", displayName: "ep.mp3", sizeBytes: 1)
        try store.markDone(id: first.id)

        let second = try store.enqueue(providerID: "p1", filePath: "a/ep.mp3", displayName: "ep.mp3", sizeBytes: 1)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(try store.hasUnfinished(providerID: "p1", filePath: "b/other.mp3"))
    }

    func testPageOrdersUnfinishedByQueuedOrderAndFinishedByMostRecentFirst() throws {
        let dbQueue = try makeDatabase()
        let store = SyncJobStore(dbQueue: dbQueue)
        try insert("a", status: .pending, createdAt: 100, updatedAt: 100, into: dbQueue)
        try insert("b", status: .pending, createdAt: 300, updatedAt: 300, into: dbQueue)
        try insert("c", status: .done, createdAt: 50, updatedAt: 500, into: dbQueue)
        try insert("d", status: .done, createdAt: 200, updatedAt: 400, into: dbQueue)
        try insert("e", status: .failed, createdAt: 250, updatedAt: 250, into: dbQueue)

        let ordered = try store.page(limit: 100).map(\.id)

        // Unfinished (pending/failed) first in queued order, then finished newest-first.
        XCTAssertEqual(ordered, ["a", "e", "b", "c", "d"])
    }

    func testPageLimitsRowsWithoutAffectingCounts() throws {
        let dbQueue = try makeDatabase()
        let store = SyncJobStore(dbQueue: dbQueue)
        for i in 0..<5 {
            try insert("job\(i)", status: .pending, createdAt: Double(i), updatedAt: Double(i), into: dbQueue)
        }
        try insert("finished", status: .done, createdAt: 99, updatedAt: 99, into: dbQueue)

        XCTAssertEqual(try store.page(limit: 2).map(\.id), ["job0", "job1"])
        let counts = try store.counts()
        XCTAssertEqual(counts.total, 6)
        XCTAssertEqual(counts.active, 5)
    }

    /// A job left `.running` by a killed app is worked by nobody, yet still counts as
    /// active — which is what made a connection read as permanently "Syncing…".
    func testRequeueOrphanedRunningPutsStrandedJobsBackInLine() throws {
        let dbQueue = try makeDatabase()
        let store = SyncJobStore(dbQueue: dbQueue)
        try insert("stranded", status: .running, createdAt: 10, updatedAt: 10, into: dbQueue)
        try insert("waiting", status: .pending, createdAt: 20, updatedAt: 20, into: dbQueue)
        try insert("finished", status: .done, createdAt: 30, updatedAt: 30, into: dbQueue)

        XCTAssertEqual(try store.requeueOrphanedRunning(), 1)

        let byID = Dictionary(uniqueKeysWithValues: try store.page(limit: 100).map { ($0.id, $0.status) })
        XCTAssertEqual(byID["stranded"], .pending)
        XCTAssertEqual(byID["waiting"], .pending)
        XCTAssertEqual(byID["finished"], .done, "a finished job must not be dragged back into the queue")
        XCTAssertEqual(try store.counts().active, 2)
    }

    func testActiveProviderIDsExcludesProvidersWithOnlyFinishedJobs() throws {
        let dbQueue = try makeDatabase()
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p2", type: "s3", label: "Other", configJSON: "", isActive: true, createdAt: Date())
        )
        let store = SyncJobStore(dbQueue: dbQueue)
        try insert("running", status: .running, createdAt: 10, updatedAt: 10, into: dbQueue)
        let finished = SyncJob(
            id: "done-p2", providerID: "p2", filePath: "x.mp3", displayName: "x.mp3",
            sizeBytes: nil, contentHash: nil, remoteModifiedAt: nil, status: .done, errorMessage: nil,
            createdAt: Date(), updatedAt: Date()
        )
        try dbQueue.write { db in try finished.save(db) }

        XCTAssertEqual(try store.activeProviderIDs(), ["p1"])
    }
}
