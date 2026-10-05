import GRDB
import XCTest
@testable import EarToListen

final class BackupServiceTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    /// `tracks.providerID` has a foreign key into `providers`, so seed a matching row
    /// if this provider id hasn't been used in this test's DB yet.
    private func makeTrack(providerID: String, filePath: String, dbQueue: DatabaseQueue) throws -> Track {
        let providerStore = ProviderStore(dbQueue: dbQueue)
        if try !providerStore.all().contains(where: { $0.id == providerID }) {
            try providerStore.upsert(ProviderRecord(id: providerID, type: "test-fake", label: providerID, configJSON: "", isActive: true, createdAt: Date()))
        }
        let track = Track(
            id: UUID().uuidString, providerID: providerID, artistID: nil, albumID: nil,
            filePath: filePath, title: filePath, durationMs: nil,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        return track
    }

    /// The failure that cost a library: the bucket was reconnected after a reinstall, so
    /// the source row was a new id, and every edit in the archive named the old one. They
    /// are the same episodes — the path says so — and they have to land.
    func testEditsLandAfterTheSourceWasReconnectedUnderANewID() throws {
        let source = try makeDatabase()
        let edited = try makeTrack(providerID: "old-id", filePath: "shows/ep3.mp3", dbQueue: source)
        var track = edited
        track.title = "The one about sleep"
        track.isFavorite = true
        track.metadataEditedAt = Date()
        try TrackStore(dbQueue: source).upsert(track, artistName: "Deep Huberman", albumName: nil)
        let snapshot = try BackupService(dbQueue: source).makeSnapshot()
        XCTAssertEqual(snapshot.episodes.count, 1)

        // The device as it is after the reinstall: same episode, synced in under the
        // connection that was added back, which got an id of its own.
        let restored = try makeDatabase()
        let resynced = try makeTrack(providerID: "new-id", filePath: "shows/ep3.mp3", dbQueue: restored)
        try BackupService(dbQueue: restored).apply(snapshot)

        let landed = try XCTUnwrap(try TrackStore(dbQueue: restored).find(id: resynced.id))
        XCTAssertEqual(landed.title, "The one about sleep")
        XCTAssertTrue(landed.isFavorite)
    }

    /// The other half of that rule: two sources holding the same path is the one case
    /// where a guess would attach the edit to the wrong episode, so it waits instead.
    func testAnEditWaitsWhenThePathNamesTwoEpisodes() throws {
        let source = try makeDatabase()
        let original = try makeTrack(providerID: "old-id", filePath: "ep.mp3", dbQueue: source)
        var track = original
        track.title = "Renamed"
        track.metadataEditedAt = Date()
        try TrackStore(dbQueue: source).upsert(track, artistName: nil, albumName: nil)
        let snapshot = try BackupService(dbQueue: source).makeSnapshot()

        let restored = try makeDatabase()
        _ = try makeTrack(providerID: "bucket-a", filePath: "ep.mp3", dbQueue: restored)
        _ = try makeTrack(providerID: "bucket-b", filePath: "ep.mp3", dbQueue: restored)
        let result = try BackupService(dbQueue: restored).apply(snapshot)

        XCTAssertEqual(result.editsAwaitingSync, 1)
        XCTAssertFalse(try TrackStore(dbQueue: restored).all().contains { $0.title == "Renamed" })
    }

    /// Restoring onto a library that's working must not cost it the episodes on screen:
    /// an archive carries none, so a swap would empty the app to put edits back.
    func testRestoringOntoALivingLibraryKeepsItsEpisodes() throws {
        let source = try makeDatabase()
        let original = try makeTrack(providerID: "old-id", filePath: "ep.mp3", dbQueue: source)
        var track = original
        track.isFavorite = true
        try TrackStore(dbQueue: source).upsert(track, artistName: nil, albumName: nil)
        let snapshot = try BackupService(dbQueue: source).makeSnapshot()

        let live = try makeDatabase()
        _ = try makeTrack(providerID: "new-id", filePath: "ep.mp3", dbQueue: live)
        _ = try makeTrack(providerID: "new-id", filePath: "untouched.mp3", dbQueue: live)
        try BackupService(dbQueue: live).apply(snapshot)

        XCTAssertEqual(try TrackStore(dbQueue: live).all().count, 2)
        XCTAssertEqual(try TrackStore(dbQueue: live).all().filter(\.isFavorite).map(\.filePath), ["ep.mp3"])
    }

    /// An empty library makes a perfectly valid archive. Shipping one is how a wipe
    /// erases the copies it was insurance against.
    func testAnEmptyLibraryIsNotSomethingToShip() throws {
        let dbQueue = try makeDatabase()
        let service = BackupService(dbQueue: dbQueue)
        XCTAssertTrue(try service.makeSnapshot().isEmpty)
        XCTAssertFalse(service.holdsData(try service.currentArchive()))

        _ = try makeTrack(providerID: "p1", filePath: "ep1.mp3", dbQueue: dbQueue)
        try PlaylistStore(dbQueue: dbQueue).create(Playlist(id: "pl1", name: "Favorites", source: "local", createdAt: Date()))
        XCTAssertFalse(try service.makeSnapshot().isEmpty)
        XCTAssertTrue(service.holdsData(try service.currentArchive()))
    }

    /// The line that answers "which of these copies do I want?" before anything is
    /// replaced — and the one thing said about an archive that holds nothing.
    func testAnArchiveSaysWhatItHoldsWithoutBeingUnpacked() throws {
        let dbQueue = try makeDatabase()
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "My Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        let artist = try LibraryStore(dbQueue: dbQueue).upsertArtist(name: "Jane Doe")
        try LibraryStore(dbQueue: dbQueue).updateArtist(id: artist.id, name: artist.name, bio: "A great host")
        let track = try makeTrack(providerID: "p1", filePath: "ep1.mp3", dbQueue: dbQueue)
        try TrackStore(dbQueue: dbQueue).setFavorite(id: track.id, isFavorite: true)
        try BookmarkStore(dbQueue: dbQueue).add(trackID: track.id, positionMs: 12_000)

        let service = BackupService(dbQueue: dbQueue)
        let snapshot = try XCTUnwrap(service.snapshot(inArchive: try service.currentArchive()))

        XCTAssertEqual(snapshot.contentsSummary, "1 episode · 1 speaker · 1 mark · 1 source")
        XCTAssertEqual(LibrarySnapshot(
            exportedAt: Date(), playlists: [], providers: [], importSources: []
        ).contentsSummary, "Nothing in it")
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let dbQueue = try makeDatabase()
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "My Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        try PlaylistStore(dbQueue: dbQueue).create(Playlist(id: "pl1", name: "Favorites", source: "local", createdAt: Date()))
        let track = try makeTrack(providerID: "p1", filePath: "ep1.mp3", dbQueue: dbQueue)
        try PlaylistStore(dbQueue: dbQueue).addTrack(track.id, toPlaylist: "pl1", at: 0)

        let service = BackupService(dbQueue: dbQueue)
        let data = try service.encode(try service.makeSnapshot())
        let decoded = try service.decode(data)

        XCTAssertEqual(decoded.providers.map(\.label), ["My Bucket"])
        XCTAssertEqual(decoded.playlists.first?.name, "Favorites")
        XCTAssertEqual(decoded.playlists.first?.tracks.first?.filePath, "ep1.mp3")
    }

    func testTranscriptsAndCorrectionsSurviveSnapshotAndRestore() throws {
        let dbQueue = try makeDatabase()
        let transcriptStore = TranscriptStore(dbQueue: dbQueue)
        let track = try makeTrack(providerID: "p1", filePath: "shows/ep9.mp3", dbQueue: dbQueue)
        try transcriptStore.save(trackID: track.id, segments: [
            TranscriptSegment(start: 0, end: 4, text: "Welcome back", engine: "onDevice"),
            TranscriptSegment(start: 4, end: 9, text: "to Deep Hooberman", engine: "onDevice"),
        ], engine: "onDevice")
        try transcriptStore.applyEdit(trackID: track.id, segmentStart: 4, newText: "to Deep Huberman")

        let service = BackupService(dbQueue: dbQueue)
        let snapshot = try service.decode(try service.encode(try service.makeSnapshot()))
        XCTAssertEqual(snapshot.transcripts.count, 1)

        // A fresh device: same provider and path, nothing transcribed yet.
        let restoredQueue = try makeDatabase()
        let restoredTrack = try makeTrack(providerID: "p1", filePath: "shows/ep9.mp3", dbQueue: restoredQueue)
        try BackupService(dbQueue: restoredQueue).apply(snapshot)

        let restoredStore = TranscriptStore(dbQueue: restoredQueue)
        XCTAssertEqual(
            try restoredStore.find(trackID: restoredTrack.id)?.map(\.text),
            ["Welcome back", "to Deep Huberman"]
        )
        XCTAssertEqual(try restoredStore.edits(trackID: restoredTrack.id).map(\.editedText), ["to Deep Huberman"])
    }

    /// Restoring the same backup twice mustn't pile up duplicate corrections.
    func testRestoringTwiceDoesNotDuplicateCorrections() throws {
        let dbQueue = try makeDatabase()
        let transcriptStore = TranscriptStore(dbQueue: dbQueue)
        let track = try makeTrack(providerID: "p1", filePath: "shows/ep9.mp3", dbQueue: dbQueue)
        try transcriptStore.save(trackID: track.id, segments: [TranscriptSegment(start: 0, end: 4, text: "before")])
        try transcriptStore.applyEdit(trackID: track.id, segmentStart: 0, newText: "after")

        let service = BackupService(dbQueue: dbQueue)
        let snapshot = try service.decode(try service.encode(try service.makeSnapshot()))
        try service.apply(snapshot)
        try service.apply(snapshot)

        XCTAssertEqual(try transcriptStore.edits(trackID: track.id).count, 1)
    }

    /// A v1 archive predates transcripts; it still has to load.
    func testAnOlderSnapshotWithoutTranscriptsStillDecodes() throws {
        let json = """
        {"version":1,"exportedAt":"2025-01-01T00:00:00Z","playlists":[],"providers":[],"importSources":[]}
        """
        let snapshot = try BackupService(dbQueue: try makeDatabase()).decode(Data(json.utf8))

        XCTAssertTrue(snapshot.transcripts.isEmpty)
    }

    func testEpisodeEditsSurviveSnapshotAndRestore() throws {
        let dbQueue = try makeDatabase()
        let trackStore = TrackStore(dbQueue: dbQueue)
        let libraryStore = LibraryStore(dbQueue: dbQueue)
        var track = try makeTrack(providerID: "p1", filePath: "podcasts/2019/part1.mp3", dbQueue: dbQueue)
        let artist = try libraryStore.upsertArtist(name: "Jane Doe")
        track.title = "The one about ferries"
        track.artistID = artist.id
        track.notes = "Recorded on the boat."
        track.artworkFileName = "art.jpg"
        track.metadataEditedAt = Date()
        try trackStore.upsert(track, artistName: artist.name, albumName: nil)

        let service = BackupService(dbQueue: dbQueue)
        let snapshot = try service.decode(try service.encode(try service.makeSnapshot()))
        XCTAssertEqual(snapshot.episodes.map(\.title), ["The one about ferries"])

        // Leave the row as a fresh sync would have written it, then restore over the top.
        var resynced = try XCTUnwrap(trackStore.find(id: track.id))
        resynced.title = "track01"
        resynced.artistID = nil
        resynced.notes = nil
        resynced.artworkFileName = nil
        resynced.metadataEditedAt = nil
        try trackStore.upsert(resynced, artistName: nil, albumName: nil)

        try service.apply(snapshot)

        let restored = try XCTUnwrap(trackStore.find(id: track.id))
        XCTAssertEqual(restored.title, "The one about ferries")
        XCTAssertEqual(restored.notes, "Recorded on the boat.")
        XCTAssertEqual(restored.artworkFileName, "art.jpg")
        XCTAssertEqual(restored.artistID, artist.id)
        XCTAssertNotNil(restored.metadataEditedAt)
    }

    /// Every synced episode travels, not just ones someone marked — the only way an
    /// untouched episode survives its bucket being deleted.
    func testSnapshotKeepsEveryEpisodeEvenOnesNobodyTouched() throws {
        let dbQueue = try makeDatabase()
        _ = try makeTrack(providerID: "p1", filePath: "untouched.mp3", dbQueue: dbQueue)

        XCTAssertEqual(try BackupService(dbQueue: dbQueue).makeSnapshot().episodes.map(\.filePath), ["untouched.mp3"])
    }

    /// The real shape this takes: the bucket was deleted on this device first (so the row
    /// is already parked on the orphaned source, same as `SameFileTests` covers), then a
    /// backup of that state restored somewhere that never had "p1" at all — a new phone,
    /// say. There's no sync that could ever produce a live row for it, so the archive
    /// fabricates one directly, marks and all.
    func testAnOrphanedEpisodeSurvivesBeingBackedUpAndRestoredElsewhere() throws {
        let source = try makeDatabase()
        let track = try makeTrack(providerID: "p1", filePath: "ep1.mp3", dbQueue: source)
        try BookmarkStore(dbQueue: source).add(trackID: track.id, positionMs: 1_000, transcriptText: "a note")
        try TrackStore(dbQueue: source).deleteAll(forProvider: "p1")
        let snapshot = try BackupService(dbQueue: source).makeSnapshot()

        let restored = try makeDatabase()
        let result = try BackupService(dbQueue: restored).apply(snapshot)

        XCTAssertEqual(result.editsAwaitingSync, 0)
        let episode = try XCTUnwrap(try TrackStore(dbQueue: restored).all(includingLost: true).first)
        XCTAssertTrue(episode.isLost)
        XCTAssertEqual(episode.providerID, OrphanedEpisodes.providerID)
        XCTAssertEqual(try BookmarkStore(dbQueue: restored).all(forTrack: episode.id).count, 1)
    }

    /// Two live sources sharing a path is still the one case a guess is worse than
    /// waiting — fabricating a stand-in would just be a second, wrong guess.
    func testAnAmbiguousPathIsNeverFabricatedEvenWithNoMatchingSource() throws {
        let dbQueue = try makeDatabase()
        _ = try makeTrack(providerID: "bucket-a", filePath: "ep.mp3", dbQueue: dbQueue)
        _ = try makeTrack(providerID: "bucket-b", filePath: "ep.mp3", dbQueue: dbQueue)
        let snapshot = LibrarySnapshot(
            exportedAt: Date(), playlists: [],
            providers: [], importSources: [],
            episodes: [LibrarySnapshot.EpisodeEntry(
                providerID: "old-id", filePath: "ep.mp3", title: "Renamed", artistName: nil, albumName: nil,
                year: nil, notes: nil, artworkFileName: nil, editedAt: Date()
            )]
        )

        let result = try BackupService(dbQueue: dbQueue).apply(snapshot)

        XCTAssertEqual(result.editsAwaitingSync, 1)
        XCTAssertFalse(try TrackStore(dbQueue: dbQueue).all(includingLost: true).contains { $0.title == "Renamed" })
    }

    func testDecodeRejectsFutureVersion() throws {
        let service = BackupService(dbQueue: try makeDatabase())
        var snapshot = LibrarySnapshot(exportedAt: Date(), playlists: [], providers: [], importSources: [])
        snapshot.version = LibrarySnapshot.currentVersion + 1
        let data = try service.encode(snapshot)

        XCTAssertThrowsError(try service.decode(data)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(LibrarySnapshot.currentVersion + 1))
        }
    }

    func testApplyMatchesAlreadySyncedTracksByProviderAndPath() throws {
        let dbQueue = try makeDatabase()
        _ = try makeTrack(providerID: "p1", filePath: "synced.mp3", dbQueue: dbQueue)
        let snapshot = LibrarySnapshot(
            exportedAt: Date(),
            playlists: [LibrarySnapshot.PlaylistEntry(
                id: "pl1", name: "Favorites", source: "local", createdAt: Date(),
                tracks: [
                    LibrarySnapshot.TrackRef(providerID: "p1", filePath: "synced.mp3", title: "Synced", position: 0),
                    LibrarySnapshot.TrackRef(providerID: "p1", filePath: "not-synced-yet.mp3", title: "Missing", position: 1),
                ]
            )],
            providers: [], importSources: []
        )

        let result = try BackupService(dbQueue: dbQueue).apply(snapshot)

        XCTAssertEqual(result.playlistsImported, 1)
        XCTAssertEqual(result.tracksMatched, 1)
        XCTAssertEqual(result.tracksUnmatched, 1)
        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).all().map(\.name), ["Favorites"])
        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).tracks(inPlaylist: "pl1").map(\.filePath), ["synced.mp3"])
    }

    func testApplyIsIdempotent() throws {
        let dbQueue = try makeDatabase()
        _ = try makeTrack(providerID: "p1", filePath: "ep1.mp3", dbQueue: dbQueue)
        let snapshot = LibrarySnapshot(
            exportedAt: Date(),
            playlists: [LibrarySnapshot.PlaylistEntry(
                id: "pl1", name: "Favorites", source: "local", createdAt: Date(),
                tracks: [LibrarySnapshot.TrackRef(providerID: "p1", filePath: "ep1.mp3", title: "Ep1", position: 0)]
            )],
            providers: [], importSources: []
        )
        let service = BackupService(dbQueue: dbQueue)

        try service.apply(snapshot)
        try service.apply(snapshot)

        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).all().count, 1)
        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).tracks(inPlaylist: "pl1").count, 1)
    }

    /// Exercises `ZipArchive` end to end: a speaker's bio/photo edit should survive
    /// round-tripping through `archive`/`unarchive` and land back on the (re-upserted)
    /// artist row via `apply`.
    func testArchiveRoundTripsSnapshotAndSpeakerPhoto() throws {
        let dbQueue = try makeDatabase()
        let libraryStore = LibraryStore(dbQueue: dbQueue)
        let artist = try libraryStore.upsertArtist(name: "Jane Doe")
        let photoFileName = try ImageFileStore.speakerPhotos.save(Data("fake-jpeg-bytes".utf8))
        addTeardownBlock { ImageFileStore.speakerPhotos.remove(photoFileName) }
        try libraryStore.updateArtist(id: artist.id, name: artist.name, bio: "A great host")
        try libraryStore.updateArtistPhoto(id: artist.id, photoFileName: photoFileName)

        let service = BackupService(dbQueue: dbQueue)
        let archived = try service.archive(try service.makeSnapshot())
        let restoredSnapshot = try service.unarchive(archived)

        XCTAssertEqual(restoredSnapshot.artists.map(\.name), ["Jane Doe"])
        XCTAssertEqual(restoredSnapshot.artists.first?.bio, "A great host")

        try service.apply(restoredSnapshot)
        let restoredArtist = try libraryStore.artists().first { $0.name == "Jane Doe" }
        XCTAssertEqual(restoredArtist?.photoFileName, photoFileName)
        XCTAssertEqual(try Data(contentsOf: ImageFileStore.speakerPhotos.url(for: photoFileName)!), Data("fake-jpeg-bytes".utf8))
    }

    func testApplySkipsProvidersAlreadyPresentLocally() throws {
        let dbQueue = try makeDatabase()
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "Local Label", configJSON: "", isActive: false, createdAt: Date())
        )
        let snapshot = LibrarySnapshot(
            exportedAt: Date(), playlists: [],
            providers: [LibrarySnapshot.ProviderEntry(id: "p1", type: "s3", label: "Backup Label", isActive: true, syncFrequencyMinutes: nil, createdAt: Date())],
            importSources: []
        )

        try BackupService(dbQueue: dbQueue).apply(snapshot)

        let providers = try ProviderStore(dbQueue: dbQueue).all()
        XCTAssertEqual(providers.map(\.label), ["Local Label"])
        XCTAssertEqual(providers.map(\.isActive), [false])
    }

    /// A provider named in the backup but not present locally — the bucket it deleted,
    /// say — comes back as a credential-less placeholder. It must land inactive even
    /// though the snapshot still calls it active: nothing reconnected its credentials,
    /// and the sync scheduler and the cloud-backup destination both loop over `isActive`
    /// providers, so an active-but-keyless one would just fail every pass until someone
    /// visits Settings — which is also where it gets switched back on.
    func testARestoredProviderComesBackInactiveUntilReconnected() throws {
        let dbQueue = try makeDatabase()
        let snapshot = LibrarySnapshot(
            exportedAt: Date(), playlists: [],
            providers: [LibrarySnapshot.ProviderEntry(id: "p1", type: "s3", label: "My Bucket", isActive: true, syncFrequencyMinutes: nil, createdAt: Date())],
            importSources: []
        )

        try BackupService(dbQueue: dbQueue).apply(snapshot)

        let providers = try ProviderStore(dbQueue: dbQueue).all()
        XCTAssertEqual(providers.map(\.label), ["My Bucket"])
        XCTAssertEqual(providers.map(\.isActive), [false])
    }
}
