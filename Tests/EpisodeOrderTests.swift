import XCTest
@testable import EarToListen

/// The order a series is listened to in — easy to get subtly wrong, `ep-10` before `ep-9`.
final class EpisodeOrderTests: XCTestCase {
    private func track(_ id: String, path: String) -> Track {
        Track(id: id, providerID: "p1", artistID: nil, albumID: "a1", filePath: path, title: id, updatedAt: Date())
    }

    func testFilenamesSortTheWayAPersonReadsThem() {
        let ordered = EpisodeOrder.ordered([
            track("ten", path: "show/ep-10.mp3"),
            track("nine", path: "show/ep-9.mp3"),
            track("one", path: "show/ep-1.mp3"),
        ])

        XCTAssertEqual(ordered.map(\.id), ["one", "nine", "ten"])
    }

    func testLeadingSequenceNumbersOrderTheFolder() {
        let ordered = EpisodeOrder.ordered([
            track("c", path: "show/003_c.mp3"),
            track("b", path: "show/014_b.mp3"),
            track("a", path: "show/002_a.mp3"),
        ])

        XCTAssertEqual(ordered.map(\.id), ["a", "c", "b"])
    }
}
