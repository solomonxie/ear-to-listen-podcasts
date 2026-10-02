import XCTest
@testable import EarToListen

final class CarLibraryTests: XCTestCase {
    func testShortListIsShownWhole() {
        XCTAssertEqual(CarLibrary.window(10, firstUnplayed: 7, limit: 12), 0..<10)
    }

    func testLongListOpensJustBeforeTheFirstUnplayed() {
        XCTAssertEqual(CarLibrary.window(412, firstUnplayed: 50, limit: 100), 48..<148)
    }

    func testWindowNeverRunsPastTheEnd() {
        XCTAssertEqual(CarLibrary.window(412, firstUnplayed: 405, limit: 100), 312..<412)
    }

    func testNothingPlayedStartsAtTheTop() {
        XCTAssertEqual(CarLibrary.window(412, firstUnplayed: nil, limit: 100), 0..<100)
    }

    private func track(durationMs: Int?, positionMs: Int? = nil, listened: Bool = false) -> Track {
        var track = Track(
            id: "t", providerID: "p", artistID: nil, albumID: nil, filePath: "t.mp3",
            title: "T", durationMs: durationMs, updatedAt: Date()
        )
        track.positionMs = positionMs
        track.listenedAt = listened ? Date() : nil
        return track
    }

    func testDetailShowsTimeLeftOnceStarted() {
        let detail = CarLibrary.detail(for: track(durationMs: 60 * 60_000, positionMs: 37 * 60_000), speaker: "Tim Keller")
        XCTAssertEqual(detail, "Tim Keller · 23 min left")
    }

    func testDetailShowsLengthWhenUnstarted() {
        XCTAssertEqual(CarLibrary.detail(for: track(durationMs: 52 * 60_000), speaker: nil), "52 min")
    }

    func testDetailSaysPlayedWhenFinished() {
        XCTAssertEqual(CarLibrary.detail(for: track(durationMs: 38 * 60_000, listened: true), speaker: "X"), "Played · 38 min")
    }

    func testNoProgressBeforeStartingOrAfterFinishing() {
        XCTAssertNil(CarLibrary.progress(of: track(durationMs: 60_000)))
        XCTAssertNil(CarLibrary.progress(of: track(durationMs: 60_000, positionMs: 30_000, listened: true)))
        XCTAssertEqual(CarLibrary.progress(of: track(durationMs: 60_000, positionMs: 30_000)), 0.5)
    }
}
