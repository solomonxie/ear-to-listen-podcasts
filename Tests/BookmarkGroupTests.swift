import XCTest
@testable import EarToListen

/// The numbering is the point of the grouping — "the second mark in that episode" has to
/// mean the second one by time, every time, or it isn't a reference to anything.
final class BookmarkGroupTests: XCTestCase {
    private func track(_ id: String) -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: nil, filePath: "\(id).mp3",
            title: "Episode \(id)", trackNumber: nil, durationMs: nil, updatedAt: Date()
        )
    }

    private func bookmark(_ id: String, track trackID: String, at positionMs: Int) -> Bookmark {
        Bookmark(id: id, trackID: trackID, positionMs: positionMs, createdAt: Date())
    }

    private func lookup(_ tracks: [Track]) -> (String) -> Track? {
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return { byID[$0] }
    }

    func testMarksAreGroupedByEpisodeAndOrderedByTime() {
        let groups = BookmarkGroup.group(
            [
                bookmark("b1", track: "t1", at: 40_000),
                bookmark("b2", track: "t1", at: 10_000),
                bookmark("b3", track: "t1", at: 25_000),
            ],
            track: lookup([track("t1")])
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bookmarks.map(\.id), ["b2", "b3", "b1"])
    }

    /// Episodes keep the order the bookmarks arrived in — newest-marked first — so the top
    /// of the list is the episode you were just in.
    func testEpisodesKeepTheOrderTheirFirstMarkArrivedIn() {
        let groups = BookmarkGroup.group(
            [
                bookmark("b1", track: "t2", at: 5_000),
                bookmark("b2", track: "t1", at: 5_000),
                bookmark("b3", track: "t2", at: 1_000),
            ],
            track: lookup([track("t1"), track("t2")])
        )

        XCTAssertEqual(groups.map(\.track.id), ["t2", "t1"])
        XCTAssertEqual(groups[0].bookmarks.map(\.id), ["b3", "b1"], "still time-ordered inside")
    }

    /// A bookmark whose episode has gone — removed from the bucket, or not synced on this
    /// device yet — must not take the section down with it.
    func testAMarkWithNoEpisodeIsDroppedRatherThanCrashing() {
        let groups = BookmarkGroup.group(
            [bookmark("b1", track: "gone", at: 1_000), bookmark("b2", track: "t1", at: 2_000)],
            track: lookup([track("t1")])
        )

        XCTAssertEqual(groups.map(\.track.id), ["t1"])
    }

    func testNoBookmarksMeansNoGroups() {
        XCTAssertTrue(BookmarkGroup.group([], track: lookup([track("t1")])).isEmpty)
    }
}
