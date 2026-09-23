import GRDB
import XCTest
@testable import EarToListen

final class TermStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "s3", label: "Bucket", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    private func addTrack(_ id: String, album: String?, to dbQueue: DatabaseQueue) throws {
        let albumID = try album.map { try LibraryStore(dbQueue: dbQueue).upsertAlbum(name: $0, artistID: nil).id }
        try TrackStore(dbQueue: dbQueue).upsert(
            Track(
                id: id, providerID: "p1", artistID: nil, albumID: albumID, filePath: "\(id).mp3",
                title: "Episode \(id)", trackNumber: nil, durationMs: nil, updatedAt: Date()
            ),
            artistName: nil, albumName: album
        )
    }

    func testTermsComeBackOrderedByMentions() throws {
        let dbQueue = try makeDatabase()
        try addTrack("t1", album: nil, to: dbQueue)
        let store = TermStore(dbQueue: dbQueue)

        try store.setTerms(["melatonin": 3, "cortisol": 9, "light": 5], forTrack: "t1")

        XCTAssertEqual(try store.terms(forTrack: "t1").map(\.name), ["cortisol", "light", "melatonin"])
        XCTAssertEqual(try store.terms(forTrack: "t1").map(\.mentions), [9, 5, 3])
    }

    /// One name, one row, one bar — whatever case each episode happened to say it in.
    func testTheSameNameInAnotherCaseJoinsTheSameTerm() throws {
        let dbQueue = try makeDatabase()
        try addTrack("t1", album: "Season 1", to: dbQueue)
        try addTrack("t2", album: "Season 1", to: dbQueue)
        let store = TermStore(dbQueue: dbQueue)

        try store.setTerms(["Huberman": 4], forTrack: "t1")
        try store.setTerms(["huberman": 2], forTrack: "t2")

        let top = try store.topTerms()
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].mentions, 6)
        XCTAssertEqual(top[0].episodes, 2)
        XCTAssertEqual(try store.episodes(forTerm: top[0].id).map(\.mentions), [4, 2])
    }

    /// An analysis pass is the authority on what an episode mentions: a re-run replaces
    /// the set rather than adding to it, and a term nothing points at any more goes.
    func testReanalysingReplacesAnEpisodesTerms() throws {
        let dbQueue = try makeDatabase()
        try addTrack("t1", album: nil, to: dbQueue)
        let store = TermStore(dbQueue: dbQueue)

        try store.setTerms(["melatonin": 3, "cortisol": 1], forTrack: "t1")
        try store.setTerms(["melatonin": 1], forTrack: "t1")

        XCTAssertEqual(try store.terms(forTrack: "t1").map(\.name), ["melatonin"])
        XCTAssertEqual(try store.topTerms().map(\.name), ["melatonin"])
    }

    func testAnAlbumSumsItsEpisodes() throws {
        let dbQueue = try makeDatabase()
        try addTrack("t1", album: "Season 1", to: dbQueue)
        try addTrack("t2", album: "Season 1", to: dbQueue)
        try addTrack("t3", album: "Season 2", to: dbQueue)
        let store = TermStore(dbQueue: dbQueue)
        try store.setTerms(["sleep": 2], forTrack: "t1")
        try store.setTerms(["sleep": 5], forTrack: "t2")
        try store.setTerms(["sleep": 100], forTrack: "t3")

        let albumID = try XCTUnwrap(TrackStore(dbQueue: dbQueue).find(id: "t1")?.albumID)
        let terms = try store.terms(forAlbum: albumID)

        XCTAssertEqual(terms.map(\.mentions), [7])
        XCTAssertEqual(terms.map(\.episodes), [2])
    }
}
