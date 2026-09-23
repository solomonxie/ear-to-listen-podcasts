import XCTest
@testable import EarToListen

/// This pass rewrites titles the listener can see, so its edges matter more than its
/// happy path: it must never renumber a run someone named by hand, and must never strip
/// a number off a title that is the only one of its kind.
final class DuplicateTitlesTests: XCTestCase {
    private func track(
        _ id: String, title: String, path: String, editedAt: Date? = nil, numberedFrom: String? = nil
    ) -> Track {
        Track(
            id: id, providerID: "p1", artistID: nil, albumID: "a1", filePath: path,
            title: title, trackNumber: nil, durationMs: nil, updatedAt: Date(),
            numberedFrom: numberedFrom, metadataEditedAt: editedAt
        )
    }

    func testIdenticalTitlesAreNumberedInFilenameOrder() {
        let renamed = DuplicateTitles.renumbered([
            track("c", title: "唯独恩典", path: "show/ep-010.mp3"),
            track("a", title: "唯独恩典", path: "show/ep-001.mp3"),
            track("b", title: "唯独恩典", path: "show/ep-002.mp3"),
        ])

        XCTAssertEqual(renamed["a"]?.title, "唯独恩典 (1)")
        XCTAssertEqual(renamed["b"]?.title, "唯独恩典 (2)")
        XCTAssertEqual(renamed["c"]?.title, "唯独恩典 (3)")
        // The receipt that makes it reversible.
        XCTAssertEqual(renamed["a"]?.numberedFrom, "唯独恩典")
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
            track("a", title: renamed["a"]!.title, path: "show/ep-001.mp3", numberedFrom: "Talk"),
            track("b", title: renamed["b"]!.title, path: "show/ep-002.mp3", numberedFrom: "Talk"),
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

        XCTAssertEqual(renamed["c"]?.title, "Talk (3)")
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

    /// The bug this column exists for: a second source disconnected, and every episode it
    /// had collided with was left reading "(2)" forever.
    func testANumberComesOffOnceThereIsNothingToTellApart() {
        let renamed = DuplicateTitles.renumbered([
            track("a", title: "唯独恩典 (2)", path: "show/ep-002.mp3", numberedFrom: "唯独恩典"),
        ])

        XCTAssertEqual(renamed["a"], DuplicateTitles.Renumbering(title: "唯独恩典", numberedFrom: nil))
    }

    /// Losing one of three renumbers the two left rather than leaving a gap, and keeps
    /// the receipt so they can still be un-numbered later.
    func testASurvivingRunIsRenumberedFromOne() {
        let renamed = DuplicateTitles.renumbered([
            track("b", title: "Talk (2)", path: "show/ep-002.mp3", numberedFrom: "Talk"),
            track("c", title: "Talk (3)", path: "show/ep-010.mp3", numberedFrom: "Talk"),
        ])

        XCTAssertEqual(renamed["b"], DuplicateTitles.Renumbering(title: "Talk (1)", numberedFrom: "Talk"))
        XCTAssertEqual(renamed["c"], DuplicateTitles.Renumbering(title: "Talk (2)", numberedFrom: "Talk"))
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
