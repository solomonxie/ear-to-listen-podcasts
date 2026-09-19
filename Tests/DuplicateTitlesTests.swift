import XCTest
@testable import EarToListen

/// This pass rewrites titles the listener can see, so its edges matter more than its
/// happy path: it must never renumber a run someone named by hand, and must never strip
/// a number off a title that is the only one of its kind.
final class DuplicateTitlesTests: XCTestCase {
    private func track(
        _ id: String, title: String, path: String, editedAt: Date? = nil
    ) -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: "a1", filePath: path,
            title: title, trackNumber: nil, durationMs: nil, updatedAt: Date(),
            metadataEditedAt: editedAt
        )
    }

    func testIdenticalTitlesAreNumberedInFilenameOrder() {
        let renamed = DuplicateTitles.renumbered([
            track("c", title: "唯独恩典", path: "show/ep-010.mp3"),
            track("a", title: "唯独恩典", path: "show/ep-001.mp3"),
            track("b", title: "唯独恩典", path: "show/ep-002.mp3"),
        ])

        XCTAssertEqual(renamed["a"], "唯独恩典 (1)")
        XCTAssertEqual(renamed["b"], "唯独恩典 (2)")
        XCTAssertEqual(renamed["c"], "唯独恩典 (3)")
    }

    func testTitlesThatAlreadyDifferAreLeftAlone() {
        let renamed = DuplicateTitles.renumbered([
            track("a", title: "Part One", path: "show/ep-001.mp3"),
            track("b", title: "Part Two", path: "show/ep-002.mp3"),
        ])

        XCTAssertTrue(renamed.isEmpty)
    }

    /// Runs after every sync, so a second pass over its own output must be a no-op.
    func testRunningItTwiceChangesNothingTheSecondTime() {
        let first = [
            track("a", title: "Talk", path: "show/ep-001.mp3"),
            track("b", title: "Talk", path: "show/ep-002.mp3"),
        ]
        let renamed = DuplicateTitles.renumbered(first)
        let settled = [
            track("a", title: renamed["a"]!, path: "show/ep-001.mp3"),
            track("b", title: renamed["b"]!, path: "show/ep-002.mp3"),
        ]

        XCTAssertTrue(DuplicateTitles.renumbered(settled).isEmpty)
    }

    /// An episode syncing in later joins the run rather than sitting beside it as a bare
    /// title — which is why the grouping works off the base name.
    func testALateArrivalJoinsAnExistingRun() {
        let renamed = DuplicateTitles.renumbered([
            track("a", title: "Talk (1)", path: "show/ep-001.mp3"),
            track("b", title: "Talk (2)", path: "show/ep-002.mp3"),
            track("c", title: "Talk", path: "show/ep-003.mp3"),
        ])

        XCTAssertEqual(renamed["c"], "Talk (3)")
        XCTAssertNil(renamed["a"], "already correct")
        XCTAssertNil(renamed["b"], "already correct")
    }

    /// The destructive case this must never do: one episode legitimately called `Encore
    /// (2)` has no run to belong to, and stripping it back to `Encore` would be the app
    /// inventing a rename nobody asked for.
    func testALoneNumberedTitleIsNotStripped() {
        let renamed = DuplicateTitles.renumbered([
            track("a", title: "Encore (2)", path: "show/ep-001.mp3"),
            track("b", title: "Something Else", path: "show/ep-002.mp3"),
        ])

        XCTAssertTrue(renamed.isEmpty)
    }

    /// A title someone typed is an answer, not a collision — touching any of the run
    /// would undo their work.
    func testARunContainingAHandEditedTitleIsLeftAlone() {
        let renamed = DuplicateTitles.renumbered([
            track("a", title: "Talk", path: "show/ep-001.mp3"),
            track("b", title: "Talk", path: "show/ep-002.mp3", editedAt: Date()),
        ])

        XCTAssertTrue(renamed.isEmpty)
    }

    func testBaseStripsOnlyATrailingNumberInBrackets() {
        XCTAssertEqual(DuplicateTitles.base(of: "Talk (3)"), "Talk")
        XCTAssertEqual(DuplicateTitles.base(of: "Talk (3) and more"), "Talk (3) and more")
        XCTAssertEqual(DuplicateTitles.base(of: "Talk (three)"), "Talk (three)")
        XCTAssertEqual(DuplicateTitles.base(of: "Talk"), "Talk")
    }
}
