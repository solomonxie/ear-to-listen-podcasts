import GRDB
import XCTest
@testable import EarToListen

/// Rearranging the lines a recogniser produced: joining ones it broke apart, cutting ones
/// it ran together. Both write the whole transcript back, so the invariant under test
/// throughout is that what comes out is still sorted, non-overlapping, and identifiable —
/// a segment's id is its start, and two lines sharing one is a list that stops drawing.
final class TranscriptMergeSplitTests: XCTestCase {
    /// `transcripts.trackID` is a foreign key, so the episode and the source behind it
    /// have to exist before there is anywhere to hang lines off.
    private func makeStore(_ lines: [(Double, Double, String)]) throws -> TranscriptStore {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        try ProviderStore(dbQueue: dbQueue).upsert(
            ProviderRecord(id: "p1", type: "test-fake", label: "p1", configJSON: "", isActive: true, createdAt: Date())
        )
        try TrackStore(dbQueue: dbQueue).upsert(
            Track(
                id: "t1", providerID: "p1", artistID: nil, albumID: nil,
                filePath: "t1.mp3", title: "t1", trackNumber: nil, durationMs: 600_000,
                sizeBytes: nil, isLost: false, updatedAt: Date()
            ),
            artistName: nil, albumName: nil
        )
        let store = TranscriptStore(dbQueue: dbQueue)
        try store.save(
            trackID: "t1",
            segments: lines.map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
        )
        return store
    }

    // MARK: Merge

    func testMergeJoinsTheTextAndSpansBothLines() throws {
        let store = try makeStore([(0, 5, "the first half"), (5, 9, "and the second")])

        let merged = try store.merge(trackID: "t1", starts: [0, 5])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "the first half and the second")
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 9)
    }

    func testMergeMarksTheResultEditedSoTheNextPassLeavesItAlone() throws {
        let store = try makeStore([(0, 5, "one"), (5, 9, "two")])

        XCTAssertTrue(try store.merge(trackID: "t1", starts: [0, 5])[0].isEdited)
    }

    func testMergeKeepsTheLinesAroundItUntouched() throws {
        let store = try makeStore([(0, 2, "before"), (2, 4, "a"), (4, 6, "b"), (6, 8, "after")])

        let merged = try store.merge(trackID: "t1", starts: [2, 4])

        XCTAssertEqual(merged.map(\.text), ["before", "a b", "after"])
    }

    /// The whole reason the button goes dim. Honouring this would either throw the line
    /// between away or swallow it into a line nobody picked.
    func testMergeRefusesASelectionWithAGapInIt() throws {
        let store = try makeStore([(0, 2, "a"), (2, 4, "skipped"), (4, 6, "b")])

        let result = try store.merge(trackID: "t1", starts: [0, 4])

        XCTAssertEqual(result.map(\.text), ["a", "skipped", "b"])
    }

    func testMergeRefusesASingleLine() throws {
        let store = try makeStore([(0, 2, "a"), (2, 4, "b")])

        XCTAssertEqual(try store.merge(trackID: "t1", starts: [0]).count, 2)
    }

    func testMergeDropsEmptyLinesRatherThanLeavingDoubleSpaces() throws {
        let store = try makeStore([(0, 2, "a"), (2, 4, ""), (4, 6, "b")])

        XCTAssertEqual(try store.merge(trackID: "t1", starts: [0, 2, 4])[0].text, "a b")
    }

    // MARK: Split

    func testSplitDividesTheTextAtTheOffsetAndTheSpanAtTheTime() throws {
        let store = try makeStore([(0, 10, "first part second part")])

        let split = try store.split(trackID: "t1", start: 0, atCharacter: 11, atTime: 4)

        XCTAssertEqual(split.map(\.text), ["first part", "second part"])
        XCTAssertEqual(split[0].start, 0)
        XCTAssertEqual(split[0].end, 4)
        XCTAssertEqual(split[1].start, 4)
        XCTAssertEqual(split[1].end, 10)
    }

    /// No spaces to divide on, which is the case this feature exists for.
    func testSplitWorksOnTextWithoutSpaces() throws {
        let store = try makeStore([(0, 10, "第一句第二句")])

        let split = try store.split(trackID: "t1", start: 0, atCharacter: 3, atTime: 5)

        XCTAssertEqual(split.map(\.text), ["第一句", "第二句"])
    }

    func testSplitRefusesACutAtEitherEndOfTheText() throws {
        let store = try makeStore([(0, 10, "one line")])

        XCTAssertEqual(try store.split(trackID: "t1", start: 0, atCharacter: 0, atTime: 5).count, 1)
        XCTAssertEqual(try store.split(trackID: "t1", start: 0, atCharacter: 8, atTime: 5).count, 1)
    }

    /// A cut that produced nothing but whitespace on one side would leave an empty line,
    /// which `rebuildLines` filters out — so the split would silently lose half the text.
    func testSplitRefusesACutThatLeavesOneSideBlank() throws {
        let store = try makeStore([(0, 10, "a       b")])

        XCTAssertEqual(try store.split(trackID: "t1", start: 0, atCharacter: 1, atTime: 5).count, 2)
        XCTAssertEqual(try store.split(trackID: "t1", start: 0, atCharacter: 2, atTime: 5).count, 2)
    }

    /// A second line starting where the first does collides with it — the id is the start.
    func testSplitClampsATimeOutsideTheSpanRatherThanCollidingTheIds() throws {
        let store = try makeStore([(0, 10, "one two")])

        for requested in [-5.0, 0.0, 10.0, 99.0] {
            let split = try store.split(trackID: "t1", start: 0, atCharacter: 4, atTime: requested)

            XCTAssertEqual(split.count, 2, "time \(requested)")
            XCTAssertGreaterThan(split[1].start, split[0].start, "time \(requested)")
            XCTAssertLessThan(split[1].start, split[1].end, "time \(requested)")
            try store.save(trackID: "t1", segments: [TranscriptSegment(start: 0, end: 10, text: "one two")])
        }
    }

    func testSplitLeavesTheRestOfTheTranscriptAlone() throws {
        let store = try makeStore([(0, 2, "before"), (2, 8, "one two"), (8, 10, "after")])

        let split = try store.split(trackID: "t1", start: 2, atCharacter: 4, atTime: 5)

        XCTAssertEqual(split.map(\.text), ["before", "one", "two", "after"])
    }

    /// Cut then joined again is the original. Not a round trip anyone performs on purpose —
    /// it's here because it fails loudly if either side mishandles the span.
    func testSplittingThenMergingGivesTheTextBack() throws {
        let store = try makeStore([(0, 10, "one two")])

        _ = try store.split(trackID: "t1", start: 0, atCharacter: 4, atTime: 5)
        let merged = try store.merge(trackID: "t1", starts: [0, 5])

        XCTAssertEqual(merged.map(\.text), ["one two"])
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 10)
    }
}
