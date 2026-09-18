import GRDB
import XCTest
@testable import EarToListen

/// Covers the reinstall path: a backup restored onto a device that hasn't synced a single
/// episode yet, and what happens to the half of it that needs those files.
final class CloudBackupTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    @discardableResult
    private func makeTrack(filePath: String, dbQueue: DatabaseQueue) throws -> Track {
        let providerStore = ProviderStore(dbQueue: dbQueue)
        if try !providerStore.all().contains(where: { $0.id == "p1" }) {
            try providerStore.upsert(ProviderRecord(id: "p1", type: "s3", label: "bucket", configJSON: "", isActive: true, createdAt: Date()))
        }
        let track = Track(
            id: UUID().uuidString, providerID: "p1", artistID: nil, albumID: nil,
            filePath: filePath, title: filePath, trackNumber: nil, durationMs: nil,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        return track
    }

    /// One device's library, playlist and transcript included.
    private func makeSnapshot() throws -> LibrarySnapshot {
        let dbQueue = try makeDatabase()
        let track = try makeTrack(filePath: "shows/ep1.mp3", dbQueue: dbQueue)
        try PlaylistStore(dbQueue: dbQueue).create(Playlist(id: "pl1", name: "Favorites", source: "local", createdAt: Date()))
        try PlaylistStore(dbQueue: dbQueue).addTrack(track.id, toPlaylist: "pl1", at: 0)
        try TranscriptStore(dbQueue: dbQueue).save(
            trackID: track.id, segments: [TranscriptSegment(start: 0, end: 3, text: "Hello")], engine: "onDevice"
        )
        let service = BackupService(dbQueue: dbQueue)
        return try service.decode(try service.encode(try service.makeSnapshot()))
    }

    /// The reinstall order: everything arrives before any episode has synced, so the parts
    /// that name a file are reported as waiting rather than dropped — then land by
    /// themselves once a sync has fetched them.
    func testWhatNeedsASyncedEpisodeLandsOnTheSyncAfterTheRestore() throws {
        let snapshot = try makeSnapshot()
        let dbQueue = try makeDatabase()
        let service = BackupService(dbQueue: dbQueue)

        let restored = try service.apply(snapshot)
        XCTAssertEqual(restored.playlistsImported, 1)
        XCTAssertEqual(restored.tracksUnmatched, 1)
        XCTAssertEqual(restored.awaitingSync, 2) // the playlist track and its transcript
        XCTAssertTrue(try PlaylistStore(dbQueue: dbQueue).tracks(inPlaylist: "pl1").isEmpty)

        let synced = try makeTrack(filePath: "shows/ep1.mp3", dbQueue: dbQueue)
        let reapplied = try service.apply(snapshot, scope: .needsSyncedTracks)

        XCTAssertEqual(reapplied.awaitingSync, 0)
        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).tracks(inPlaylist: "pl1").map(\.id), [synced.id])
        XCTAssertEqual(try TranscriptStore(dbQueue: dbQueue).find(trackID: synced.id)?.map(\.text), ["Hello"])
    }

    /// The re-apply runs after every sync, so it must never undo what the listener did in
    /// between.
    func testReapplyingAfterASyncDoesNotReviveADeletedPlaylist() throws {
        let snapshot = try makeSnapshot()
        let dbQueue = try makeDatabase()
        let service = BackupService(dbQueue: dbQueue)
        try service.apply(snapshot)
        try PlaylistStore(dbQueue: dbQueue).delete(id: "pl1")

        try makeTrack(filePath: "shows/ep1.mp3", dbQueue: dbQueue)
        try service.apply(snapshot, scope: .needsSyncedTracks)

        XCTAssertTrue(try PlaylistStore(dbQueue: dbQueue).all().isEmpty)
    }

}
