import XCTest
@testable import EarToListen

/// What the model is shown is all it can reason from — a mark without its episode or its
/// note is a timestamp, and a budget that halves an episode hands it a fragment.
final class BookmarkInsightsTests: XCTestCase {
    private func mark(_ id: String, at ms: Int, note: String? = nil, tags: String? = nil, said: String? = nil) -> Bookmark {
        Bookmark(id: id, trackID: "t", positionMs: ms, note: note, tags: tags, transcriptText: said, createdAt: Date())
    }

    func testEpisodeCarriesBylineAndEachMarkItsTimeTagsNoteAndLine() {
        let text = BookmarkInsights.describe(.init(
            title: "Sleep", speaker: "Huberman", collection: "Lab",
            marks: [mark("a", at: 734_000, note: "try this", tags: "health, sleep", said: "Get morning light")]
        ))
        XCTAssertEqual(text, """
        ## Sleep — Huberman · Lab
        - @12:14 [health, sleep] note: try this said: "Get morning light"
        """)
    }

    func testBareMarkIsJustItsTime() {
        let text = BookmarkInsights.describe(.init(title: "E", speaker: nil, collection: nil, marks: [mark("a", at: 5_000, note: "  ")]))
        XCTAssertEqual(text, "## E\n- @0:05")
    }

    func testBudgetDropsWholeOlderEpisodesButAlwaysKeepsTheNewest() {
        let long = String(repeating: "x", count: 100)
        let episodes = (1...3).map { i in
            BookmarkInsights.EpisodeMarks(title: "E\(i)", speaker: nil, collection: nil, marks: [mark("m\(i)", at: 0, note: long)])
        }
        let one = BookmarkInsights.describe(episodes[0]).count
        let block = BookmarkInsights.block(episodes, budget: one * 2)
        XCTAssertTrue(block.contains("## E1"))
        XCTAssertTrue(block.contains("## E2"))
        XCTAssertFalse(block.contains("## E3"))
        XCTAssertTrue(BookmarkInsights.block(episodes, budget: 10).contains("## E1"))
    }
}
