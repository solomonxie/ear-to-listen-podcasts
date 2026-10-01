import GRDB
import XCTest
@testable import EarToListen

final class DemoDataSeederTests: XCTestCase {
    func testSeedsAPlayableLibraryWithEveryFeatureFilledIn() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try DemoDataSeeder.seed(into: dbQueue)

        let tracks = try TrackStore(dbQueue: dbQueue).all(includingLost: true)
        XCTAssertEqual(tracks.count, 12)
        XCTAssertEqual(Set(tracks.compactMap(\.fingerprint)).count, 12, "no two episodes may fold into one")
        XCTAssertTrue(tracks.allSatisfy { Bundle.main.url(forResource: $0.filePath, withExtension: nil) != nil })
        XCTAssertTrue(tracks.contains { $0.listenedAt != nil })
        XCTAssertTrue(tracks.contains { ($0.positionMs ?? 0) > 0 && $0.listenedAt == nil })

        let transcribed = try TranscriptStore(dbQueue: dbQueue).transcribedTrackIDs()
        XCTAssertEqual(transcribed.count, 12)
        XCTAssertFalse(try BookmarkStore(dbQueue: dbQueue).all().isEmpty)
        XCTAssertFalse(try TermStore(dbQueue: dbQueue).topTerms().isEmpty)
        XCTAssertEqual(try PlaylistStore(dbQueue: dbQueue).all().count, 3)

        let summary = try XCTUnwrap(tracks.first { $0.title == "Your Files, Your Rules" }?.summary)
        XCTAssertFalse(summary.contains("{"), "every {line} marker becomes a time")
        XCTAssertTrue(summary.contains("[0:"))
    }

    func testMarkersBecomeLineStartTimes() {
        XCTAssertEqual(DemoDataSeeder.fillMarkers("• {1} a • {10} b", starts: Array(stride(from: 0.0, to: 66, by: 6))), "• [0:06] a • [1:00] b")
    }
}
