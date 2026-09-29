import XCTest
@testable import EarToListen

/// A history row has to say where an episode stopped, and a finished one must start again
/// from the top rather than resume at its last second.
final class ListenHistoryTests: XCTestCase {
    private func track(positionMs: Int?, durationMs: Int? = 2_462_000) -> Track {
        var track = Track(
            id: "t", providerID: "p", artistID: nil, albumID: nil, filePath: "s/ep.mp3",
            title: "Ep", trackNumber: nil, durationMs: durationMs, updatedAt: Date()
        )
        track.positionMs = positionMs
        return track
    }

    func testPartWayThroughSaysWhereItStopped() {
        let detail = ListenHistorySection.detail(for: track(positionMs: 734_000))
        XCTAssertTrue(detail.hasSuffix("stopped at 12:14 / 41:02"), detail)
    }

    func testTheLastFewSecondsCountAsFinished() {
        XCTAssertTrue(ListenHistorySection.isFinished(track(positionMs: 2_460_000)))
        XCTAssertFalse(ListenHistorySection.isFinished(track(positionMs: 2_400_000)))
        XCTAssertFalse(ListenHistorySection.isFinished(track(positionMs: 5_000, durationMs: nil)))
        XCTAssertTrue(ListenHistorySection.detail(for: track(positionMs: 2_462_000)).hasSuffix("finished"))
    }

    func testListenedIsOneOfTheAppsOwnLists() {
        XCTAssertTrue(FixedPlaylist.allCases.contains(.listened))
    }
}
