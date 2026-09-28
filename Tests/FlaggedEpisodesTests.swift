import XCTest
@testable import EarToListen

/// The count in Settings is the whole feature, so what it counts — and what it refuses to
/// count twice — is what's worth pinning down.
final class FlaggedEpisodesTests: XCTestCase {
    private func track(
        _ id: String, title: String = "A Real Title", path: String = "show/ep-001.mp3",
        artist: String? = "ar1", album: String? = "a1", number: Int? = 1
    ) -> Track {
        Track(
            id: id, providerID: "p1", artistID: artist, albumID: album, filePath: path,
            title: title, trackNumber: number, durationMs: nil, updatedAt: Date()
        )
    }

    func testAFullyDescribedEpisodeIsNotFlagged() {
        let reasons = FlaggedEpisodes.reasons(for: track("a"), hasTranscript: true)
        XCTAssertTrue(reasons.isEmpty)
    }

    func testATitleTakenFromTheFilenameCounts() {
        let named = track("a", title: "ep-001", path: "show/ep-001.mp3")
        XCTAssertTrue(FlaggedEpisodes.reasons(for: named, hasTranscript: true).contains(.filenameTitle))
    }

    /// `DuplicateTitles` turns a run of identical filename titles into "ep-001 (2)",
    /// which says no more than the filename did.
    func testANumberedFilenameTitleStillCounts() {
        let named = track("a", title: "ep-001 (2)", path: "show/ep-001.mp3")
        XCTAssertTrue(FlaggedEpisodes.reasons(for: named, hasTranscript: true).contains(.filenameTitle))
    }

    func testMissingEitherASpeakerOrACollectionCountsOnce() {
        let noSpeaker = FlaggedEpisodes.reasons(for: track("a", artist: nil), hasTranscript: true)
        let neither = FlaggedEpisodes.reasons(for: track("b", artist: nil, album: nil), hasTranscript: true)
        XCTAssertEqual(noSpeaker, [.unplaced])
        XCTAssertEqual(neither, [.unplaced])
    }

    func testTheTotalCountsEpisodesRatherThanProblems() {
        let bare = track("bare", title: "ep-009", path: "show/ep-009.mp3", artist: nil, album: nil, number: nil)
        let summary = FlaggedEpisodes.summary(tracks: [bare, track("fine")], transcribed: ["fine"])

        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.count(.noTranscript), 1)
        XCTAssertEqual(summary.count(.unplaced), 1)
        XCTAssertEqual(summary.count(.filenameTitle), 1)
        XCTAssertEqual(summary.count(.noNumber), 1)
    }
}
