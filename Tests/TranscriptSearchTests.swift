import GRDB
import XCTest
@testable import EarToListen

/// Searching what was said. The named half of search is `LibrarySearchTests`.
final class TranscriptSearchTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "test-fake", label: "p1", configJSON: "", isActive: true, createdAt: Date())
        )
        return dbQueue
    }

    private func addEpisode(_ id: String, lines: [String], in dbQueue: DatabaseQueue) throws {
        let track = Track(
            id: id, providerID: "p1", artistID: nil, albumID: nil,
            filePath: "\(id).mp3", title: id, trackNumber: nil, durationMs: 600_000,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        let segments = lines.enumerated().map { index, text in
            TranscriptSegment(start: Double(index) * 6, end: Double(index) * 6 + 5, text: text)
        }
        try TranscriptStore(dbQueue: dbQueue).save(trackID: id, segments: segments)
    }

    func testFindsTheLineThatWasSaid() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: [
            "Good morning.", "The ferries leave at dawn.", "That's all for today.",
        ], in: dbQueue)

        let matches = try TranscriptSearch(dbQueue: dbQueue).matches(for: "ferries")

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.trackID, "harbour")
        XCTAssertEqual(try XCTUnwrap(matches.first?.start), 6, accuracy: 0.0001)
    }

    /// One line is a few seconds of speech — too little to recognise the moment from.
    func testAMatchCarriesTheLinesAroundIt() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: [
            "Good morning.", "The ferries leave at dawn.", "That's all for today.",
        ], in: dbQueue)

        let text = try XCTUnwrap(TranscriptSearch(dbQueue: dbQueue).matches(for: "ferries").first?.text)

        XCTAssertTrue(text.contains("Good morning."))
        XCTAssertTrue(text.contains("That's all for today."))
    }

    func testMatchingIsCaseInsensitive() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: ["The Ferries leave at dawn."], in: dbQueue)

        XCTAssertFalse(try TranscriptSearch(dbQueue: dbQueue).matches(for: "FERRIES").isEmpty)
    }

    /// Chinese is written without spaces, so a substring match is the whole mechanism
    /// there — and it works without a tokenizer.
    func testFindsChineseWithoutWordBreaks() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("chuandao", lines: ["今天要查的经文是传道书的第一章。"], in: dbQueue)

        XCTAssertFalse(try TranscriptSearch(dbQueue: dbQueue).matches(for: "传道书").isEmpty)
    }

    /// A letter or two matches every transcript in the library, and the scan is the
    /// expensive half of search.
    func testTooShortToSearchFor() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: ["The ferries leave at dawn."], in: dbQueue)

        XCTAssertTrue(try TranscriptSearch(dbQueue: dbQueue).matches(for: "t").isEmpty)
    }

    /// One repetitive episode must not fill the section.
    func testAtMostThreeLinesFromOneEpisode() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: (0..<10).map { "Ferries again, take \($0)." }, in: dbQueue)

        XCTAssertEqual(try TranscriptSearch(dbQueue: dbQueue).matches(for: "ferries").count, 3)
    }

    func testNothingSaidIt() throws {
        let dbQueue = try makeDatabase()
        try addEpisode("harbour", lines: ["The ferries leave at dawn."], in: dbQueue)

        XCTAssertTrue(try TranscriptSearch(dbQueue: dbQueue).matches(for: "kubernetes").isEmpty)
    }
}
