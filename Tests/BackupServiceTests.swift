import GRDB
import XCTest
@testable import BringYourOwnPodcasts

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
            filePath: filePath, title: filePath, trackNumber: nil, durationMs: nil,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        return track
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
        let photoFileName = try SpeakerPhotoStore.save(Data("fake-jpeg-bytes".utf8))
        addTeardownBlock { SpeakerPhotoStore.remove(photoFileName) }
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
        XCTAssertEqual(try Data(contentsOf: SpeakerPhotoStore.url(for: photoFileName)!), Data("fake-jpeg-bytes".utf8))
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
}
