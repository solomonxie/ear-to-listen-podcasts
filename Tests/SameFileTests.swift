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
            title: (path as NSString).deletingPathExtension, durationMs: durationMs, sizeBytes: sizeBytes, contentHash: nil, updatedAt: Date()
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

    /// A deleted bucket destroys the ability to play an episode that lived only there —
    /// never the listener's history or notes on it. Those stay on the row, which parks on
    /// the standing "orphaned" source rather than the one that's gone.
    func testDisconnectingTheOnlySourceLosesTheEpisodeButKeepsItsMarksAndNotes() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try store.setFavorite(id: "a", isFavorite: true)
        try BookmarkStore(dbQueue: dbQueue).add(trackID: "a", positionMs: 1000, transcriptText: "a note worth keeping")

        try store.deleteAll(forProvider: "p1")

        let episode = try XCTUnwrap(try store.find(id: "a"))
        XCTAssertTrue(episode.isLost)
        XCTAssertEqual(episode.providerID, OrphanedEpisodes.providerID)
        XCTAssertTrue(episode.isFavorite, "the mark is the listener's, not the sync's")
        XCTAssertEqual(try BookmarkStore(dbQueue: dbQueue).all(forTrack: "a").count, 1, "the note survives")
    }

    /// An orphaned episode still shows up on its album page — that's the one place a
    /// listener would go looking for its notes once the bucket is gone — but never in a
    /// play queue or picker, which only have a dead file to offer.
    func testAnOrphanedEpisodeIsOnItsAlbumPageButNotAPlayQueue() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        let album = try LibraryStore(dbQueue: dbQueue).upsertAlbum(name: "Test Album", artistID: nil)
        var episode = track(id: "missing", path: "shows/ep1.mp3")
        episode.albumID = album.id
        try store.upsert(episode, artistName: nil, albumName: "Test Album")
        try store.deleteAll(forProvider: "p1")

        XCTAssertTrue(try store.tracks(forAlbum: album.id).isEmpty, "a play queue skips it")
        XCTAssertEqual(try store.tracks(forAlbum: album.id, includingLost: true).map(\.id), ["missing"])
    }

    /// The same recording, reconnected under a different bucket entirely: the orphaned row
    /// is what the fingerprint match finds, so the episode plays again with its old marks
    /// and notes intact rather than arriving as a brand new one.
    func testAnOrphanedEpisodeRelinksWhenTheSameRecordingReturnsInAnotherBucket() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "shows/ep1.mp3"), artistName: nil, albumName: nil)
        try BookmarkStore(dbQueue: dbQueue).add(trackID: "a", positionMs: 1000, transcriptText: "a note worth keeping")
        try store.deleteAll(forProvider: "p1")

        try store.upsert(
            track(id: "c", provider: "p2", path: "renamed-bucket/ep1.mp3"), artistName: nil, albumName: nil
        )

        let episode = try XCTUnwrap(try store.find(id: "a"))
        XCTAssertFalse(episode.isLost)
        XCTAssertEqual(episode.providerID, "p2")
        XCTAssertEqual(episode.filePath, "renamed-bucket/ep1.mp3")
        XCTAssertEqual(try store.all().count, 1, "the arrival is the same episode, not a new one")
        XCTAssertEqual(try BookmarkStore(dbQueue: dbQueue).all(forTrack: "a").count, 1)
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

    /// A new bucket's file arrives with no duration yet — the ETag and byte count off the
    /// listing alone are enough to re-link the orphaned episode.
    func testAnOrphanedEpisodeRelinksByETagBeforeAnythingIsDownloaded() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        var old = track(id: "a", path: "ep1.mp3")
        old.contentHash = "abc123"
        try store.upsert(old, artistName: nil, albumName: nil)
        try store.deleteAll(forProvider: "p1")

        var arrival = track(id: "c", provider: "p2", path: "other/name.mp3", durationMs: nil)
        arrival.contentHash = "abc123"
        try store.upsert(arrival, artistName: nil, albumName: nil)

        let episode = try XCTUnwrap(try store.find(id: "a"))
        XCTAssertFalse(episode.isLost)
        XCTAssertEqual(episode.providerID, "p2")
        XCTAssertEqual(try store.all(includingLost: true).count, 1)
    }

    func testDeleteLostRemovesOnlyEpisodesWithNoAudio() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(track(id: "a", path: "ep1.mp3"), artistName: nil, albumName: nil)
        try store.deleteAll(forProvider: "p1")
        try store.upsert(track(id: "b", provider: "p2", path: "x.mp3", sizeBytes: 1, durationMs: 1000), artistName: nil, albumName: nil)

        XCTAssertEqual(try store.deleteLost(), 1)
        XCTAssertEqual(try store.all(includingLost: true).map(\.id), ["b"])
    }
}

final class NeglectTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO providers (id, type, label, configJSON, isActive, createdAt) VALUES ('p1','s3','b','{}',1,?)",
                arguments: [Date()]
            )
        }
        return dbQueue
    }

    private func episode(_ id: String, album: String? = nil) -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: album, filePath: "\(id).mp3", title: id,
            durationMs: 1000, sizeBytes: Int64(id.hashValue & 0xFFFF) + 1, contentHash: nil, updatedAt: Date()
        )
    }

    func testANeglectedEpisodeIsHiddenButKeptAndSurvivesASyncUpsert() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(episode("a"), artistName: nil, albumName: nil)
        try store.setNeglected(ids: ["a"], neglected: true)

        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertEqual(try store.neglectedEpisodes().map(\.id), ["a"])
        XCTAssertEqual(try store.neglectedPaths(providerID: "p1"), ["a.mp3"])

        var again = episode("a")
        again.id = "other-id"
        try store.upsert(again, artistName: nil, albumName: nil)
        XCTAssertNotNil(try XCTUnwrap(try store.find(id: "a")).neglectedAt)

        try store.setNeglected(ids: ["a"], neglected: false)
        XCTAssertEqual(try store.all().map(\.id), ["a"])
    }

    func testNeglectingAnAlbumHidesItsEpisodesAndNewArrivals() throws {
        let dbQueue = try makeDatabase()
        let store = TrackStore(dbQueue: dbQueue)
        let library = LibraryStore(dbQueue: dbQueue)
        let album = try library.upsertAlbum(name: "Show", artistID: nil)
        try store.upsert(episode("a", album: album.id), artistName: nil, albumName: "Show")
        try library.setAlbumNeglected(id: album.id, neglected: true)
        try store.upsert(episode("b", album: album.id), artistName: nil, albumName: "Show")

        XCTAssertTrue(try library.albums().isEmpty)
        XCTAssertEqual(try library.neglectedAlbums().map(\.id), [album.id])
        XCTAssertTrue(try store.all().isEmpty)
        XCTAssertTrue(try store.neglectedEpisodes().isEmpty, "hidden by the album, not on their own")

        try library.setAlbumNeglected(id: album.id, neglected: false)
        XCTAssertEqual(try store.all().count, 2)
    }

    func testNeglectedEpisodesTravelInABackup() throws {
        let source = try makeDatabase()
        try TrackStore(dbQueue: source).upsert(episode("a"), artistName: nil, albumName: nil)
        try TrackStore(dbQueue: source).setNeglected(ids: ["a"], neglected: true)
        let snapshot = try BackupService(dbQueue: source).makeSnapshot()
        XCTAssertNotNil(snapshot.episodes.first?.neglectedAt)
    }
}

final class FlaggedFixTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "b", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    private func add(_ path: String, size: Int64, to dbQueue: DatabaseQueue) throws {
        let name = (path as NSString).deletingPathExtension
        try TrackStore(dbQueue: dbQueue).upsert(
            Track(id: path, providerID: "p1", filePath: path, title: name, durationMs: 1000, sizeBytes: size, updatedAt: Date()),
            artistName: nil, albumName: nil
        )
    }

    func testTidyTitleDropsSeparatorsAndTrackNumbers() {
        func tidy(_ path: String) -> String? {
            FlaggedFixer.tidiedTitle(of: Track(id: "x", providerID: "p1", filePath: path, title: "x", updatedAt: Date()))
        }
        XCTAssertEqual(tidy("a/03_my_great_talk.mp3"), "my great talk")
        XCTAssertNil(tidy("ep-001.mp3"))
    }

    func testBatchFixAppliesToWhatFitsAndLogsIt() async throws {
        let dbQueue = try makeDatabase()
        try add("01_one.mp3", size: 1, to: dbQueue)
        try add("two.mp3", size: 2, to: dbQueue)
        let items = try TrackStore(dbQueue: dbQueue).flaggedItems()
        XCTAssertEqual(items.count, 2)

        let outcome = await FlaggedFixer(dbQueue: dbQueue).apply(.tidyTitle, to: items)

        XCTAssertEqual(outcome.fixed, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(try TrackStore(dbQueue: dbQueue).find(id: "01_one.mp3")?.title, "one")
        let history = try FixHistoryStore(dbQueue: dbQueue).all()
        XCTAssertEqual(history.map(\.action), ["Tidy title"])
        XCTAssertEqual(history.first?.count, 1)
    }

    func testDeleteRecordOnlyTakesEpisodesWithNoAudio() async throws {
        let dbQueue = try makeDatabase()
        try add("a.mp3", size: 1, to: dbQueue)
        try TrackStore(dbQueue: dbQueue).deleteAll(forProvider: "p1")
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "b", configJSON: "", isActive: true, createdAt: Date())
        )
        try add("b.mp3", size: 2, to: dbQueue)
        let items = try TrackStore(dbQueue: dbQueue).flaggedItems()

        let outcome = await FlaggedFixer(dbQueue: dbQueue).apply(.deleteRecord, to: items)

        XCTAssertEqual(outcome.fixed, 1)
        XCTAssertEqual(try TrackStore(dbQueue: dbQueue).everything().map(\.id), ["b.mp3"])
    }
}

final class ScanThenTagsTests: XCTestCase {
    func testAListingBecomesEntriesAtOnceAndTagsFillThemInLater() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "b", configJSON: "", isActive: true, createdAt: Date())
        )
        let store = TrackStore(dbQueue: dbQueue)
        let files = (1...500).map {
            CloudFile(id: "k\($0)", name: "ep\($0).mp3", path: "show/ep\($0).mp3", sizeBytes: Int64($0), contentHash: "h\($0)")
        }

        XCTAssertEqual(try store.registerListed(files, providerID: "p1", sidecars: [:]), 500)
        XCTAssertEqual(try store.all().count, 500)
        XCTAssertEqual(try store.needsTagsCount(), 500)
        XCTAssertEqual(try store.registerListed(files, providerID: "p1", sidecars: [:]), 0, "a second scan adds nothing")

        let first = try XCTUnwrap(try store.needingTags(limit: 1, excluding: []).first)
        try store.applyTags(
            id: first.id, title: "A Real Title", durationMs: 60_000, year: 2020, artistName: "Speaker", albumName: "Show"
        )
        XCTAssertEqual(try store.needsTagsCount(), 499)
        let tagged = try XCTUnwrap(try store.find(id: first.id))
        XCTAssertEqual(tagged.title, "A Real Title")
        XCTAssertNotNil(tagged.artistID)
        XCTAssertNotNil(tagged.fingerprint)
    }
}

final class ScanDuplicateFoldTests: XCTestCase {
    func testAScannedFileFoldsIntoTheLostEpisodeOnceItsLengthIsKnown() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        for id in ["old", "new"] {
            try ProviderStore(dbQueue: dbQueue).upsert(
                ProviderRecord(id: id, type: "s3", label: id, configJSON: "", isActive: true, createdAt: Date())
            )
        }
        let store = TrackStore(dbQueue: dbQueue)
        try store.upsert(
            Track(id: "a", providerID: "old", filePath: "show/ep1.mp3", title: "Ep 1", durationMs: 3_600_000,
                  sizeBytes: 50_000, contentHash: "etag-old", updatedAt: Date()),
            artistName: nil, albumName: nil
        )
        try store.setListened(ids: ["a"], listened: true)
        try store.deleteAll(forProvider: "old")

        let files = [CloudFile(id: "k", name: "ep1.mp3", path: "other/ep1.mp3", sizeBytes: 50_000, contentHash: "etag-new")]
        try store.registerListed(files, providerID: "new", sidecars: [:])
        XCTAssertEqual(try store.everything().count, 2, "different ETag: not matched from the listing alone")

        let scanned = try XCTUnwrap(try store.needingTags(limit: 1, excluding: []).first)
        try store.applyTags(id: scanned.id, title: nil, durationMs: 3_600_400, year: nil, artistName: nil, albumName: nil)

        let all = try store.everything()
        XCTAssertEqual(all.count, 1)
        let episode = try XCTUnwrap(all.first)
        XCTAssertEqual(episode.id, "a", "the one with history is kept")
        XCTAssertFalse(episode.isLost)
        XCTAssertEqual(episode.providerID, "new")
        XCTAssertEqual(episode.filePath, "other/ep1.mp3")
        XCTAssertNotNil(episode.listenedAt)
    }

    func testFreshDatabaseMigratesInOrder() throws {
        let dbQueue = try DatabaseQueue()
        XCTAssertNoThrow(try Migrations.migrator().migrate(dbQueue))
    }
}
