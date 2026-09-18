import XCTest
@testable import EarToListen

final class MatcherTests: XCTestCase {
    private func makeTrack(title: String, artistID: String? = "artist1", durationMs: Int? = 180_000) -> Track {
        Track(
            id: UUID().uuidString,
            providerID: "provider1",
            artistID: artistID,
            albumID: nil,
            filePath: "\(title).mp3",
            title: title,
            trackNumber: nil,
            durationMs: durationMs,
            sizeBytes: nil,
            isLost: false,
            updatedAt: Date()
        )
    }

    func testExactMatchScoresAboveAutoAcceptThreshold() {
        let track = makeTrack(title: "Hello World")
        let imported = ImportedTrack(title: "Hello World", artist: "The Band", album: nil, durationMs: 180_000, isrc: nil)

        let match = TrackMatcher.bestMatch(for: imported, in: [track], artistNames: ["artist1": "The Band"])

        XCTAssertNotNil(match)
        XCTAssertGreaterThanOrEqual(match!.confidence, TrackMatcher.autoAcceptThreshold)
    }

    func testDurationMismatchLowersConfidenceBelowAutoAccept() {
        let track = makeTrack(title: "Hello World", durationMs: 180_000)
        let imported = ImportedTrack(title: "Hello World", artist: "The Band", album: nil, durationMs: 60_000, isrc: nil)

        let match = TrackMatcher.bestMatch(for: imported, in: [track], artistNames: ["artist1": "The Band"])

        XCTAssertNotNil(match)
        XCTAssertLessThan(match!.confidence, TrackMatcher.autoAcceptThreshold)
    }

    func testFeaturedArtistSuffixDoesNotPreventMatch() {
        let track = makeTrack(title: "Hello World")
        let imported = ImportedTrack(title: "Hello World (feat. Someone)", artist: "The Band", album: nil, durationMs: 180_000, isrc: nil)

        let match = TrackMatcher.bestMatch(for: imported, in: [track], artistNames: ["artist1": "The Band"])

        XCTAssertNotNil(match)
        XCTAssertGreaterThanOrEqual(match!.confidence, TrackMatcher.autoAcceptThreshold)
    }

    func testBestMatchPicksHighestScoringTrack() {
        let wrongTrack = makeTrack(title: "Completely Different")
        let rightTrack = makeTrack(title: "Hello World")
        let imported = ImportedTrack(title: "Hello World", artist: "The Band", album: nil, durationMs: 180_000, isrc: nil)

        let match = TrackMatcher.bestMatch(for: imported, in: [wrongTrack, rightTrack], artistNames: ["artist1": "The Band"])

        XCTAssertEqual(match?.track.id, rightTrack.id)
    }

    func testEmptyLibraryReturnsNoMatch() {
        let imported = ImportedTrack(title: "Anything", artist: "Someone", album: nil, durationMs: nil, isrc: nil)
        XCTAssertNil(TrackMatcher.bestMatch(for: imported, in: [], artistNames: [:]))
    }
}
