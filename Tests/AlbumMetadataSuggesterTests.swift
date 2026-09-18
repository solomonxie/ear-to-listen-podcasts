import GRDB
import XCTest
@testable import EarToListen

final class AlbumMetadataSuggesterTests: XCTestCase {
    private static let album = Album(id: "a1", artistID: nil, name: "Collected talks")

    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "test-fake", label: "p1", configJSON: "", isActive: true, createdAt: Date())
        )
        // `tracks.albumID` is a foreign key, so the album has to exist before its episodes.
        try dbQueue.write { try Self.album.insert($0) }
        return dbQueue
    }

    @discardableResult
    private func makeTrack(_ path: String, coveredTo: Double?, dbQueue: DatabaseQueue) throws -> Track {
        let track = Track(
            id: UUID().uuidString, providerID: "p1", artistID: nil, albumID: "a1",
            filePath: path, title: "Collected talks", trackNumber: nil, durationMs: 60_000,
            sizeBytes: nil, isLost: false, updatedAt: Date()
        )
        try TrackStore(dbQueue: dbQueue).upsert(track, artistName: nil, albumName: nil)
        if let coveredTo {
            try TranscriptStore(dbQueue: dbQueue).save(
                trackID: track.id, segments: [TranscriptSegment(start: 0, end: coveredTo, text: "words")]
            )
        }
        return track
    }

    /// The batch pass reads only what's already on the phone: a half-transcribed or
    /// untranscribed episode is reported as skipped, never downloaded or guessed at.
    func testOnlyFullyTranscribedEpisodesTakePart() throws {
        let dbQueue = try makeDatabase()
        let whole = try makeTrack("a/1.mp3", coveredTo: 60, dbQueue: dbQueue)
        let half = try makeTrack("a/2.mp3", coveredTo: 30, dbQueue: dbQueue)
        let none = try makeTrack("a/3.mp3", coveredTo: nil, dbQueue: dbQueue)

        let partition = AlbumMetadataSuggester(dbQueue: dbQueue).partition(tracks: [whole, half, none])

        XCTAssertEqual(partition.ready.map(\.filePath), ["a/1.mp3"])
        XCTAssertEqual(partition.skipped.map(\.filePath), ["a/2.mp3", "a/3.mp3"])
    }

    func testAnalyzeRefusesAnAlbumWithNothingTranscribed() async throws {
        let dbQueue = try makeDatabase()
        let track = try makeTrack("a/1.mp3", coveredTo: nil, dbQueue: dbQueue)

        do {
            _ = try await AlbumMetadataSuggester(dbQueue: dbQueue).analyze(album: Self.album, artistName: nil, tracks: [track])
            XCTFail("expected an album with no finished transcript to be refused")
        } catch {
            XCTAssertTrue(error is AlbumMetadataSuggester.NothingToAnalyzeError)
        }
    }

    func testBatchResultToleratesAPartialResponse() throws {
        let json = """
        {"album": {"name": "Harbour Talks", "artist": null, "notes": "Six evenings."},
         "episodes": [{"index": 0, "title": "Ferries at dawn"},
                      {"title": "no index, dropped"},
                      {"index": 2, "title": "Low tide", "year": "2019"}]}
        """
        let object = try XCTUnwrap(EpisodeMetadataSuggester.jsonObject(in: json))
        let result = try JSONDecoder().decode(AlbumMetadataSuggester.Result.self, from: Data(object.utf8))

        XCTAssertEqual(result.album?.name, "Harbour Talks")
        XCTAssertEqual(result.episodes.map(\.index), [0, 2])
        XCTAssertEqual(result.episodes.last?.year, 2019)
    }
}
