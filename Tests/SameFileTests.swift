import GRDB
import XCTest
@testable import EarToListen

/// One recording, however many files it is stored as.
final class SameFileTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        for id in ["p1", "p2"] {
            try ProviderStore(dbQueue: dbQueue).upsert(
                ProviderRecord(id: id, type: "s3", label: id, configJSON: "", isActive: true, createdAt: Date())
            )
        }
        return dbQueue
    }

    private func track(
        id: String, provider: String = "p1", path: String, sizeBytes: Int64? = 5_000_000,
        durationMs: Int? = 1_800_000
    ) -> Track {
        Track(
            id: id, providerID: provider, artistID: nil, albumID: nil, filePath: path,
            title: (path as NSString).deletingPathExtension, trackNumber: nil,
            durationMs: durationMs, sizeBytes: sizeBytes, contentHash: nil, updatedAt: Date()
        )
    }

    func testAFileWithNoLengthIsNeverFoldedWithAnything() {
        XCTAssertNil(FileFingerprint.of(sizeBytes: 5_000_000, durationMs: nil))
        XCTAssertNil(FileFingerprint.of(sizeBytes: nil, durationMs: 1_800_000))
        XCTAssertEqual(
            FileFingerprint.of(sizeBytes: 5_000_000, durationMs: 1_800_400),
            FileFingerprint.of(sizeBytes: 5_000_000, durationMs: 1_800_000),
            "the same file read twice can disagree by milliseconds"
        )
        XCTAssertNotEqual(
            FileFingerprint.of(sizeBytes: 5_000_001, durationMs: 1_800_000),
            FileFingerprint.of(sizeBytes: 5_000_000, durationMs: 1_800_000)
        )
    }

    func testTheSameFileInTwoBucketsIsOneEpisodeInTwoPlaces() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(
            track(id: "b", provider: "p2", path: "archive/episode-one.mp3"), artistName: nil, albumName: nil
        )

        let tracks = try store.all()
        XCTAssertEqual(tracks.count, 1, "a copy is a second place, not a second episode")
        let copies = try TrackFileStore(dbQueue: dbQueue).all(forTrack: tracks[0].id)
        XCTAssertEqual(copies.map(\.filePath).sorted(), ["archive/episode-one.mp3", "shows/ep1.mp3"])
        XCTAssertEqual(tracks[0].filePath, "shows/ep1.mp3", "it still plays from the one it knew first")
    }

    func testARenamedCopyInTheSameBucketIsTheSameEpisode() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", path: "ep1 (copy).mp3"), artistName: nil, albumName: nil)

        XCTAssertEqual(try store.all().count, 1)
    }

    func testADifferentRecordingStaysItsOwnEpisode() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", path: "ep2.mp3", sizeBytes: 6_000_000), artistName: nil, albumName: nil)

        XCTAssertEqual(try store.all().count, 2)
    }

    func testAnEpisodeIsOnlyLostOnceEveryCopyIs() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", provider: "p2", path: "archive/ep1.mp3"), artistName: nil, albumName: nil)

        // The bucket it plays from stops listing it.
        XCTAssertEqual(try store.markLost(providerID: "p1", keepingPaths: []), 0)
        var episode = try XCTUnwrap(try store.all().first)
        XCTAssertFalse(episode.isLost, "the other copy is still there")
        XCTAssertEqual(episode.filePath, "archive/ep1.mp3", "so it plays from that one now")

        XCTAssertEqual(try store.markLost(providerID: "p2", keepingPaths: []), 1)
        episode = try XCTUnwrap(try store.all().first)
        XCTAssertTrue(episode.isLost)
    }

    func testDisconnectingOneSourceLeavesAnEpisodeThatIsAlsoSomewhereElse() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", provider: "p2", path: "archive/ep1.mp3"), artistName: nil, albumName: nil)

        try store.deleteAll(forProvider: "p1")

        let episode = try XCTUnwrap(try store.all().first)
        XCTAssertEqual(episode.providerID, "p2")
        XCTAssertEqual(episode.filePath, "archive/ep1.mp3")
        XCTAssertEqual(try TrackFileStore(dbQueue: dbQueue).all(forTrack: episode.id).count, 1)
    }

    func testDisconnectingTheOnlySourceStillTakesTheEpisode() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)

        try store.deleteAll(forProvider: "p1")

        XCTAssertTrue(try store.all().isEmpty)
    }

    /// The bucket browser and a restore both ask "what episode is this file?" — of a
    /// second copy, `tracks` alone says nothing, and tapping it in the browser refused to
    /// play something the library knew.
    func testAFileIsFoundByEveryCopyItIsStoredAs() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", provider: "p2", path: "archive/ep1.mp3"), artistName: nil, albumName: nil)

        XCTAssertEqual(try store.find(providerID: "p2", filePath: "archive/ep1.mp3")?.id, "a")
        XCTAssertEqual(try store.find(filePath: "archive/ep1.mp3").map(\.id), ["a"])
    }

    /// Editing an episode goes through the same `upsert` an import does, and must save
    /// the edit rather than deciding the row is a copy of something.
    func testEditingAnEpisodeThatHasCopiesStillSaves() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.upsert(track(id: "b", provider: "p2", path: "archive/ep1.mp3"), artistName: nil, albumName: nil)

        var episode = try XCTUnwrap(try store.find(id: "a"))
        episode.title = "Renamed by hand"
        try store.saveEdit(episode, artistName: nil, albumName: nil)

        XCTAssertEqual(try store.find(id: "a")?.title, "Renamed by hand")
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try TrackFileStore(dbQueue: dbQueue).all(forTrack: "a").count, 2)
    }

    /// The library as it stands today: imported twice before anything checked, with the
    /// listener's own work spread across both rows.
    func testFoldingDuplicatesAlreadyInTheLibraryKeepsWhatWasMarked() throws {
        let dbQueue = try makeDatabase()
        try dbQueue.write { db in
            for (id, path) in [("a", "shows/ep1.mp3"), ("b", "archive/ep1.mp3")] {
                var row = track(id: id, path: path)
                row.fingerprint = FileFingerprint.of(row)
                if id == "b" { row.metadataEditedAt = Date() }
                try row.insert(db)
                try TrackFile(primaryOf: row).insert(db)
            }
        }
        try BookmarkStore(dbQueue: dbQueue).add(trackID: "a", positionMs: 1000, transcriptText: "here")

        try dbQueue.write { db in try TrackMerge.foldDuplicates(in: db) }

        let tracks = try TrackStore(dbQueue: dbQueue).all()
        XCTAssertEqual(tracks.map(\.id), ["b"], "the hand-edited row is the one that stays")
        XCTAssertEqual(try BookmarkStore(dbQueue: dbQueue).all(forTrack: "b").count, 1)
        XCTAssertEqual(try TrackFileStore(dbQueue: dbQueue).all(forTrack: "b").count, 2)
    }
}
