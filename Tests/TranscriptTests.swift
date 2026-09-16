import XCTest
@testable import BringYourOwnPodcasts

final class TranscriptCoverageTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, text: String = "line", isEdited: Bool = false) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, isEdited: isEdited)
    }

    func testGapsIgnoreShortPausesBetweenSegments() {
        let segments = [segment(0, 10), segment(11, 20)]

        let gaps = TranscriptCoverage.gaps(in: segments, duration: 20)

        XCTAssertTrue(gaps.isEmpty)
    }

    func testGapsCoverTheHeadTheMiddleAndTheTail() {
        let segments = [segment(30, 60), segment(90, 120)]

        let gaps = TranscriptCoverage.gaps(in: segments, duration: 200)

        XCTAssertEqual(gaps, [
            TimeWindow(start: 0, end: 30),
            TimeWindow(start: 60, end: 90),
            TimeWindow(start: 120, end: 200),
        ])
    }

    func testNothingTranscribedMeansOneGapOverTheWholeEpisode() {
        let gaps = TranscriptCoverage.gaps(in: [], duration: 300)

        XCTAssertEqual(gaps, [TimeWindow(start: 0, end: 300)])
    }

    func testOverlappingSegmentsCountAsOneCoveredSpan() {
        let segments = [segment(0, 30), segment(20, 45)]

        XCTAssertEqual(TranscriptCoverage.coveredSeconds(segments), 45)
    }

    func testWindowsAreCappedAndOrderedFromThePlayhead() {
        let windows = TranscriptCoverage.windows(in: [], duration: 180, windowSeconds: 60, from: 130)

        XCTAssertEqual(windows, [
            TimeWindow(start: 120, end: 180),
            TimeWindow(start: 0, end: 60),
            TimeWindow(start: 60, end: 120),
        ])
    }

    func testAFullyTranscribedEpisodeHasNoWindowsLeft() {
        let segments = [segment(0, 100)]

        XCTAssertTrue(TranscriptCoverage.windows(in: segments, duration: 100, windowSeconds: 60).isEmpty)
    }

    @MainActor
    func testSilenceIsPaddedSoAWindowIsNeverSentTwice() {
        let window = TimeWindow(start: 60, end: 120)
        let lines = [segment(70, 80, text: "hello")]

        let padded = LiveTranscript.padded(lines, toCover: window, engine: "onDevice")

        // Only the window itself is filled in — everything before it is still a gap.
        XCTAssertEqual(TranscriptCoverage.gaps(in: padded, duration: 120, minimumGap: 0.5), [TimeWindow(start: 0, end: 60)])
        XCTAssertEqual(padded.filter { !$0.text.isEmpty }.count, 1)
    }

    func testAnUnsetEndTimeIsBackfilledFromTheNextLine() {
        let legacy = [TranscriptSegment(start: 0, text: "a"), TranscriptSegment(start: 12, text: "b")]

        let normalized = TranscriptSegment.normalized(legacy, tailSeconds: 4)

        XCTAssertEqual(normalized[0].end, 12)
        XCTAssertEqual(normalized[1].end, 16)
    }
}

final class TranscriptMergeTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, text: String, isEdited: Bool = false) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text, isEdited: isEdited)
    }

    func testAnEditedLineSurvivesReTranscription() {
        let existing = [segment(0, 10, text: "Dr Huberman", isEdited: true)]
        let incoming = [segment(0, 10, text: "Dr Hooberman")]

        let merged = TranscriptStore.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.map(\.text), ["Dr Huberman"])
    }

    func testAnUntouchedLineIsReplacedBySomethingCoveringTheSameTime() {
        let existing = [segment(0, 10, text: "old")]
        let incoming = [segment(0, 10, text: "new")]

        let merged = TranscriptStore.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.map(\.text), ["new"])
    }

    func testANewWindowSlotsInBesideWhatWasAlreadyThere() {
        let existing = [segment(0, 10, text: "first")]
        let incoming = [segment(60, 70, text: "later")]

        let merged = TranscriptStore.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.map(\.text), ["first", "later"])
    }
}

final class TranscriptContextTests: XCTestCase {
    private func edit(_ original: String, _ edited: String) -> TranscriptEdit {
        TranscriptEdit(
            id: UUID().uuidString, trackID: "t1", segmentStart: 0,
            originalText: original, editedText: edited, createdAt: Date()
        )
    }

    /// Only genuinely new words count — a re-capitalised one was already recognised.
    func testOnlyTheWordsTheUserAddedBecomeHints() {
        let context = TranscriptionContext.from(edits: [edit("welcome to deep dive", "welcome to Deep Dhyve")])

        XCTAssertEqual(context.phrases, ["Dhyve"])
    }

    func testNoEditsMeansNoPrompt() {
        XCTAssertNil(TranscriptionContext.from(edits: []).prompt)
    }
}

final class WordDiffTests: XCTestCase {
    func testASwappedWordShowsAsOneRemovalAndOneAddition() {
        let tokens = WordDiff.tokens(from: "the quick brown fox", to: "the quick red fox")

        XCTAssertEqual(tokens.filter { $0.kind == .removed }.map(\.text), ["brown"])
        XCTAssertEqual(tokens.filter { $0.kind == .added }.map(\.text), ["red"])
        XCTAssertEqual(tokens.filter { $0.kind == .same }.map(\.text), ["the", "quick", "fox"])
    }

    func testIdenticalTextHasNoChanges() {
        let tokens = WordDiff.tokens(from: "same words", to: "same words")

        XCTAssertTrue(tokens.allSatisfy { $0.kind == .same })
    }
}
