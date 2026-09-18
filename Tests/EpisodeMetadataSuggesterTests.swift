import GRDB
import XCTest
@testable import EarToListen

final class EpisodeMetadataSuggesterTests: XCTestCase {
    private func decode(_ json: String) throws -> EpisodeMetadataSuggester.Suggestion {
        let object = try XCTUnwrap(EpisodeMetadataSuggester.jsonObject(in: json))
        return try JSONDecoder().decode(EpisodeMetadataSuggester.Suggestion.self, from: Data(object.utf8))
    }

    func testReadsJSONWrappedInProseAndFences() throws {
        let suggestion = try decode("""
        Sure! Here's the metadata:
        ```json
        {"title": "Ferries at dawn", "artist": "Jane Doe", "album": null,
         "show": null, "year": 2019, "notes": "A walk through the harbour."}
        ```
        """)

        XCTAssertEqual(suggestion.title, "Ferries at dawn")
        XCTAssertEqual(suggestion.artist, "Jane Doe")
        XCTAssertNil(suggestion.album)
        XCTAssertEqual(suggestion.year, 2019)
    }

    /// A field in the wrong shape should cost that field, not the whole suggestion.
    func testToleratesOddFieldTypes() throws {
        let suggestion = try decode(#"{"title": "Part one", "year": "2019-03-14", "artist": 12, "notes": "  "}"#)

        XCTAssertEqual(suggestion.title, "Part one")
        XCTAssertEqual(suggestion.year, 2019)
        XCTAssertNil(suggestion.artist)
        XCTAssertNil(suggestion.notes)
    }

    func testNoJSONAtAll() {
        XCTAssertNil(EpisodeMetadataSuggester.jsonObject(in: "I can't help with that."))
    }

    // MARK: Readiness

    private func makeTrack(durationMs: Int?, dbQueue: DatabaseQueue) throws -> Track {
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "test-fake", label: "p1", configJSON: "", isActive: true, createdAt: Date())
        )
        let track = Track(
            id: UUID().uuidString, providerID: "p1", artistID: nil, albumID: nil,
            filePath: "ep.mp3", title: "ep", trackNumber: nil, durationMs: durationMs,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        return track
    }

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    func testNotReadyWithoutATranscript() throws {
        let dbQueue = try makeDatabase()
        let track = try makeTrack(durationMs: 60_000, dbQueue: dbQueue)

        XCTAssertEqual(EpisodeMetadataSuggester(dbQueue: dbQueue).readiness(track: track), .noTranscript)
    }

    func testNotReadyWhileTranscriptIsStillPartial() throws {
        let dbQueue = try makeDatabase()
        let track = try makeTrack(durationMs: 60_000, dbQueue: dbQueue)
        try TranscriptStore(dbQueue: dbQueue).save(
            trackID: track.id, segments: [TranscriptSegment(start: 0, end: 20, text: "the first third")]
        )

        guard case .partial(let coverage) = EpisodeMetadataSuggester(dbQueue: dbQueue).readiness(track: track) else {
            return XCTFail("expected a partial transcript to block suggesting")
        }
        XCTAssertEqual(coverage, 1.0 / 3, accuracy: 0.01)
    }

    func testReadyOnlyWhenTheWholeEpisodeIsCovered() throws {
        let dbQueue = try makeDatabase()
        let track = try makeTrack(durationMs: 60_000, dbQueue: dbQueue)
        try TranscriptStore(dbQueue: dbQueue).save(
            trackID: track.id, segments: [TranscriptSegment(start: 0, end: 60, text: "all of it")]
        )

        XCTAssertEqual(EpisodeMetadataSuggester(dbQueue: dbQueue).readiness(track: track), .ready)
    }

    func testUnknownDurationCannotBeJudgedComplete() throws {
        let dbQueue = try makeDatabase()
        let track = try makeTrack(durationMs: nil, dbQueue: dbQueue)
        try TranscriptStore(dbQueue: dbQueue).save(
            trackID: track.id, segments: [TranscriptSegment(start: 0, end: 60, text: "all of it")]
        )

        XCTAssertEqual(EpisodeMetadataSuggester(dbQueue: dbQueue).readiness(track: track), .unknownDuration)
    }

    /// An over-budget transcript must still reach the end of the episode, not just its opening.
    func testSamplingSpansTheWholeTranscript() {
        let text = (0..<1000).map { "line\($0)" }.joined(separator: " ")
        let sampled = EpisodeMetadataSuggester.sampled(text, budget: 600, chunks: 6)

        XCTAssertLessThan(sampled.count, text.count)
        XCTAssertTrue(sampled.hasPrefix("line0 "))
        XCTAssertTrue(sampled.hasSuffix("line999"))
    }
}
