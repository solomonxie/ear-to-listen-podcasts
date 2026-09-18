import XCTest
@testable import EarToListen

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

    func testAJumpElsewhereAbandonsTheWindowInFlight() {
        let inFlight = TimeWindow(start: 0, end: 30)

        XCTAssertFalse(TranscriptCoverage.isWorthFinishing(
            inFlight, in: [], duration: 3600, windowSeconds: 30, playhead: 1800
        ))
    }

    func testPlayingOnThroughAWindowDoesNotAbandonIt() {
        let inFlight = TimeWindow(start: 0, end: 30)

        // Still inside it, and just past it — normal drift while the engine works.
        XCTAssertTrue(TranscriptCoverage.isWorthFinishing(
            inFlight, in: [], duration: 3600, windowSeconds: 30, playhead: 20
        ))
        XCTAssertTrue(TranscriptCoverage.isWorthFinishing(
            inFlight, in: [], duration: 3600, windowSeconds: 30, playhead: 55
        ))
    }

    /// Listening to an already-transcribed stretch while the only gap left is far away:
    /// the distance alone must not cancel the one window there is to do.
    func testADistantGapIsNotAbandonedWhenItIsTheOnlyOneLeft() {
        let segments = [segment(0, 600)]
        let inFlight = TimeWindow(start: 600, end: 630)

        XCTAssertTrue(TranscriptCoverage.isWorthFinishing(
            inFlight, in: segments, duration: 630, windowSeconds: 30, playhead: 60
        ))
    }

    func testAFullyTranscribedEpisodeHasNoWindowsLeft() {
        let segments = [segment(0, 100)]

        XCTAssertTrue(TranscriptCoverage.windows(in: segments, duration: 100, windowSeconds: 60).isEmpty)
    }

    @MainActor
    func testSilenceIsPaddedSoAWindowIsNeverSentTwice() {
        let window = TimeWindow(start: 60, end: 120)
        let lines = [segment(70, 80, text: "hello")]

        let padded = TranscriptRunner.padded(lines, toCover: window, engine: "onDevice")

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

    func testSilenceCannotDeleteLinesThatAreAlreadyThere() {
        let existing = [segment(2, 6, text: "first"), segment(7, 12, text: "second")]
        // A window that came back describing only its tail, padded out as silence.
        let incoming = [segment(20, 26, text: "late line"), segment(0, 20, text: "")]

        let merged = TranscriptStore.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(merged.filter { !$0.text.isEmpty }.map(\.text), ["first", "second", "late line"])
    }

    func testSilenceIsTrimmedBackToTheStretchesNobodySpokeIn() {
        let existing = [segment(10, 20, text: "spoken")]
        let incoming = [segment(0, 30, text: "")]

        let merged = TranscriptStore.merging(existing: existing, incoming: incoming)

        XCTAssertEqual(
            merged.filter { $0.text.isEmpty }.map { TimeWindow(start: $0.start, end: $0.end) },
            [TimeWindow(start: 0, end: 10), TimeWindow(start: 20, end: 30)]
        )
        // Still fully accounted for, so none of it is sent out a second time.
        XCTAssertTrue(TranscriptCoverage.gaps(in: merged, duration: 30).isEmpty)
    }

    func testSilenceStillLandsWhereNothingWasSaid() {
        let merged = TranscriptStore.merging(existing: [], incoming: [segment(0, 30, text: "")])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(TranscriptCoverage.gaps(in: merged, duration: 30).isEmpty)
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

final class TranscriptLineTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ duration: Double = 0.3) -> RecognizedWord {
        RecognizedWord(text: text, start: start, duration: duration)
    }

    func testAClosedSentenceEndsALine() {
        let lines = TranscriptLines.grouped(
            [word("Hello", 0), word("there.", 0.4), word("Next", 1.0), word("thing", 1.4)],
            startOffset: 0, engine: "onDevice"
        )

        XCTAssertEqual(lines.map(\.text), ["Hello there.", "Next thing"])
    }

    func testAPauseEndsALine() {
        let lines = TranscriptLines.grouped(
            [word("before", 0), word("after", 3)], startOffset: 0, engine: "onDevice", pauseSeconds: 0.7
        )

        XCTAssertEqual(lines.map(\.text), ["before", "after"])
    }

    func testStartOffsetRebasesOntoTheEpisodeTimeline() {
        let lines = TranscriptLines.grouped([word("word", 2)], startOffset: 600, engine: "onDevice")

        XCTAssertEqual(lines.first?.start, 602)
    }

    func testAHypothesisShorterThanTheStabilityWindowIsAllVolatile() {
        let draft = TranscriptLines.split(
            [word("just", 0), word("started", 0.4)], startOffset: 0, engine: "onDevice", stabilitySeconds: 2
        )

        XCTAssertTrue(draft.settled.isEmpty)
        XCTAssertEqual(draft.volatile, ["just started"])
    }

    func testOlderWordsSettleAndTheTailStaysVolatile() {
        let words = [word("old", 0), word("words", 0.5), word("brand", 9.5), word("new", 9.9)]

        let draft = TranscriptLines.split(words, startOffset: 0, engine: "onDevice", stabilitySeconds: 2)

        XCTAssertEqual(draft.settled.map(\.text), ["old words"])
        XCTAssertEqual(draft.volatile, ["brand new"])
    }

    /// The property the lyric list's identity depends on: appending later words must never
    /// move the start time of a line that has already settled.
    func testSettledStartsDoNotMoveAsMoreWordsArrive() {
        let early = [word("one.", 0), word("two", 5)]
        let later = early + [word("three", 5.4), word("four", 5.8)]

        let before = TranscriptLines.split(early, startOffset: 0, engine: "onDevice")
        let after = TranscriptLines.split(later, startOffset: 0, engine: "onDevice")

        XCTAssertEqual(before.settled.first?.start, after.settled.first?.start)
    }

    /// The bug behind "no phrase-by-phrase left, it keeps rewriting the same word":
    /// partial results carry no word timings, so pause- and length-based splitting had
    /// nothing to work with and the whole window came out as one ever-changing line.
    func testUntimedPartialsStillBreakIntoPhrases() {
        let untimed = "the quick brown fox jumps over the lazy dog and then keeps running onward"
            .split(separator: " ").map { RecognizedWord(text: String($0), start: 0, duration: 0) }

        XCTAssertFalse(TranscriptLines.hasTimings(untimed))
        let draft = TranscriptLines.split(untimed, startOffset: 0, engine: "onDevice")

        XCTAssertTrue(draft.settled.isEmpty, "nothing can settle without timings")
        XCTAssertGreaterThan(draft.volatile.count, 1, "must not collapse into one line")
        XCTAssertEqual(draft.volatile.joined(separator: " ").split(separator: " ").count, untimed.count)
    }

    func testUntimedPartialsBreakOnSentenceEnds() {
        let untimed = ["你好。", "今天", "天气", "很好。"].map { RecognizedWord(text: $0, start: 0, duration: 0) }

        let draft = TranscriptLines.split(untimed, startOffset: 0, engine: "onDevice")

        XCTAssertEqual(draft.volatile, ["你好。", "今天天气很好。"])
    }

    func testAHypothesisThatRestartsDoesNotDiscardWhatCameBefore() {
        let first = [word("Welcome", 0, 1), word("back", 1.1, 0.5)]
        // The recognizer starts a new utterance part-way through the window.
        let restarted = [word("to", 8, 0.4), word("the", 8.5, 0.3), word("show.", 8.9, 0.6)]

        let heard = TranscriptLines.absorbing(restarted, into: TranscriptLines.absorbing(first, into: []))

        XCTAssertEqual(heard.map(\.text), ["Welcome", "back", "to", "the", "show."])
    }

    func testAHypothesisThatRevisesFromTheTopReplacesTheLot() {
        let first = [word("Welcome", 0, 1), word("Beck", 1.1, 0.5)]
        let revised = [word("Welcome", 0, 1), word("back", 1.1, 0.5)]

        let heard = TranscriptLines.absorbing(revised, into: TranscriptLines.absorbing(first, into: []))

        XCTAssertEqual(heard.map(\.text), ["Welcome", "back"])
    }

    func testUntimedHypothesesAreNotFoldedIn() {
        let timed = [word("Welcome", 0, 1)]
        let untimed = [word("something", 0, 0)]

        let heard = TranscriptLines.absorbing(untimed, into: TranscriptLines.absorbing(timed, into: []))

        XCTAssertEqual(heard.map(\.text), ["Welcome"])
    }

    func testNoWordsMeansAnEmptyDraft() {
        XCTAssertTrue(TranscriptLines.split([], startOffset: 0, engine: "onDevice").isEmpty)
    }
}

final class TranscriptFileTests: XCTestCase {
    func testSidecarPathSwapsTheExtension() {
        XCTAssertEqual(TranscriptFile.sidecarPath(forAudioPath: "shows/ep1.mp3", extension: "vtt"), "shows/ep1.vtt")
    }

    func testVTTRoundTripsTimesTextAndSilence() throws {
        let original = [
            TranscriptSegment(start: 4.12, end: 8.9, text: "Welcome back.", engine: "onDevice"),
            TranscriptSegment(start: 8.9, end: 40, text: "", engine: "onDevice"),
            TranscriptSegment(start: 40, end: 44, text: "Corrected line", engine: "onDevice", isEdited: true),
        ]

        let parsed = TranscriptFile.parse(TranscriptFile.vtt(from: original), extension: "vtt")

        XCTAssertEqual(parsed.map(\.text), ["Welcome back.", "", "Corrected line"])
        XCTAssertEqual(try XCTUnwrap(parsed.first).end, 8.9, accuracy: 0.01)
        XCTAssertEqual(parsed.first(where: { $0.text == "Corrected line" })?.isEdited, true)
        XCTAssertEqual(parsed.first?.engine, "onDevice")
    }

    /// The whole point of VTT being canonical: a listened-but-silent stretch must not read
    /// back as a gap, or it gets transcribed again on every pass forever.
    func testSilenceSurvivesAVTTRoundTripSoItIsNotRescanned() {
        let original = [
            TranscriptSegment(start: 0, end: 10, text: "talking", engine: "onDevice"),
            TranscriptSegment(start: 10, end: 120, text: "", engine: "onDevice"),
        ]

        let parsed = TranscriptFile.parse(TranscriptFile.vtt(from: original), extension: "vtt")

        XCTAssertTrue(TranscriptCoverage.gaps(in: parsed, duration: 120).isEmpty)
    }

    func testSRTIsReadWithItsSequenceNumbersAndCommaDecimals() {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,500
        First line

        2
        00:00:05,000 --> 00:00:07,000
        Second line
        """

        let parsed = TranscriptFile.parse(srt, extension: "srt")

        XCTAssertEqual(parsed.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(parsed[0].end, 4.5, accuracy: 0.01)
    }

    func testLRCHeaderTagsAreSkippedAndEndsAreBackfilled() {
        let lrc = """
        [ti:Episode One]
        [ar:Some Host]
        [00:04.12]Welcome back.
        [01:20.00]Much later.
        """

        let parsed = TranscriptFile.parse(lrc, extension: "lrc")

        XCTAssertEqual(parsed.map(\.text), ["Welcome back.", "Much later."])
        XCTAssertEqual(parsed[0].start, 4.12, accuracy: 0.01)
        // No end times in LRC — the next line's start fills it in.
        XCTAssertEqual(parsed[0].end, 80, accuracy: 0.01)
    }

    func testLRCRepeatsTextForEveryTimestampOnALine() {
        let parsed = TranscriptFile.parse("[00:10.00][00:30.00]chorus", extension: "lrc")

        XCTAssertEqual(parsed.map(\.start), [10, 30])
    }

    func testEnhancedLRCWordTimingsAreStrippedFromTheText() {
        let parsed = TranscriptFile.parse("[00:10.00]<00:10.00>hello <00:10.50>world", extension: "lrc")

        XCTAssertEqual(parsed.first?.text, "hello world")
    }

    func testPodcastIndexJSONIsReadWithSpeakers() {
        let json = """
        {"version":"1.0.0","segments":[
          {"startTime":0.0,"endTime":4.0,"speaker":"Alex","body":"Hello"},
          {"startTime":4.0,"endTime":8.0,"body":"No speaker here"}
        ]}
        """

        let parsed = TranscriptFile.parse(json, extension: "json")

        XCTAssertEqual(parsed.map(\.text), ["Alex: Hello", "No speaker here"])
    }

    func testPlainTextIsSpreadAcrossTheEpisode() throws {
        let parsed = TranscriptFile.parse("One. Two. Three.", extension: "txt", duration: 90)

        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed.first?.start, 0)
        XCTAssertEqual(try XCTUnwrap(parsed.last).end, 90, accuracy: 0.01)
        XCTAssertTrue(TranscriptCoverage.gaps(in: parsed, duration: 90).isEmpty)
    }

    func testInterpolationIsMonotonicAndGapless() throws {
        let segments = TranscriptFile.interpolated(
            "First one. Second one is longer. Third.", over: TimeWindow(start: 60, end: 180), engine: nil
        )

        XCTAssertEqual(segments.first?.start, 60)
        XCTAssertEqual(try XCTUnwrap(segments.last).end, 180, accuracy: 0.01)
        for (earlier, later) in zip(segments, segments.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.end, later.start + 0.001)
            XCTAssertLessThan(earlier.start, earlier.end)
        }
    }

    func testCRLFAndBOMAreTolerated() {
        let vtt = "\u{FEFF}WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nHello\r\n"

        XCTAssertEqual(TranscriptFile.parse(vtt, extension: "vtt").map(\.text), ["Hello"])
    }

    func testMalformedInputYieldsNothingRatherThanCrashing() {
        XCTAssertTrue(TranscriptFile.parse("not a transcript at all", extension: "vtt").isEmpty)
        XCTAssertTrue(TranscriptFile.parse("", extension: "srt").isEmpty)
        XCTAssertTrue(TranscriptFile.parse("{}", extension: "json").isEmpty)
    }

    func testLRCTimeFormatsPastAnHourInMinutes() {
        XCTAssertEqual(TranscriptFile.lrcTime(5000), "83:20.00")
        XCTAssertEqual(TranscriptFile.vttTime(5000), "01:23:20.000")
    }
}

final class FileKindTests: XCTestCase {
    func testOnlyAudioCountsAsAnEpisode() {
        XCTAssertTrue(FileKind(path: "shows/ep1.mp3").isPlayable)
        XCTAssertTrue(FileKind(path: "shows/ep1.M4A").isPlayable)
        for path in ["byop-backup.json", ".byop/library-backup.zip", "ep1.vtt", "cover.jpg", "notes.txt", "noext"] {
            XCTAssertFalse(FileKind(path: path).isPlayable, "\(path) must never sync as an episode")
        }
    }

    func testTextAndTranscriptsArePreviewable() {
        XCTAssertTrue(FileKind(path: "ep1.vtt").isReadableAsText)
        XCTAssertTrue(FileKind(path: "ep1.lrc").isReadableAsText)
        XCTAssertTrue(FileKind(path: "notes.json").isReadableAsText)
        XCTAssertFalse(FileKind(path: "library-backup.zip").isReadableAsText)
        XCTAssertFalse(FileKind(path: "ep1.mp3").isReadableAsText)
    }

    /// The old backup was a zip named `.json`, so a name-based preview would have rendered
    /// it as pages of noise. Content decides, not the extension.
    func testAZipNamedJSONIsRecognizedByItsBytes() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0x41), count: 32))

        XCTAssertNotNil(FilePreviewSheet.describeBinary(zip))
        XCTAssertNil(FilePreviewSheet.describeBinary(Data("plain readable text".utf8)))
    }

    func testBinaryContentIsNotShownAsText() {
        XCTAssertNotNil(FilePreviewSheet.describeBinary(Data([0x41, 0x00, 0x42])))
    }
}

final class FileKindDeletionTests: XCTestCase {
    /// The demo library's clips carry no extension, and neither might someone's own files.
    /// Sync is allowed to skip them; the migration is never allowed to delete them.
    func testExtensionlessFilesAreNeverDeleted() {
        XCTAssertFalse(FileKind(path: "ep-tech-1").isPlayable)
        XCTAssertFalse(FileKind(path: "ep-tech-1").isKnownNonAudio)
    }

    func testOnlyRecognizedNonAudioIsDeletable() {
        for path in ["byop-backup.json", ".byop/library-backup.zip", "ep1.vtt", "cover.jpg"] {
            XCTAssertTrue(FileKind(path: path).isKnownNonAudio, "\(path) should be cleared out")
        }
        XCTAssertFalse(FileKind(path: "ep1.mp3").isKnownNonAudio)
    }
}

final class TranscriptLocaleTests: XCTestCase {
    /// The phone's language says nothing about the episode's — asking for Chinese must
    /// give a Chinese recognizer, not fall through to en-US.
    func testAnExplicitLanguageIsHonoured() {
        let resolved = AppleSpeechTranscriber.resolvedLocale("zh-CN")

        XCTAssertEqual(resolved.language.languageCode?.identifier, "zh")
    }

    func testAnUnsupportedLanguageFallsBackRatherThanFailing() {
        XCTAssertEqual(
            AppleSpeechTranscriber.resolvedLocale("xx-YY").identifier(.bcp47),
            "en-US"
        )
    }

    /// ICU-style identifiers have to resolve too — that mismatch is what sent every
    /// episode through en-US in the first place.
    func testICUStyleIdentifiersResolve() {
        XCTAssertEqual(
            AppleSpeechTranscriber.resolvedLocale("zh_Hans_CN").language.languageCode?.identifier,
            "zh"
        )
    }
}

/// What the on-device recognizer actually hands over on a long Chinese episode, and what
/// has to be done with it before it reads as a transcript.
final class RecognizerHypothesisTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ duration: Double = 0.3) -> RecognizedWord {
        RecognizedWord(text: text, start: start, duration: duration)
    }

    /// Chinese doesn't put spaces between words, and a recognizer hands its text over one
    /// token at a time whatever the language.
    func testJoinsWithoutSpacesInScriptsThatHaveNone() {
        XCTAssertEqual(TranscriptLines.joined(["涉及到", "这", "两", "中队", "的"]), "涉及到这两中队的")
        XCTAssertEqual(TranscriptLines.joined(["so", "the", "model", "runs"]), "so the model runs")
        // A language name in the middle of a Chinese sentence keeps its own spacing.
        XCTAssertEqual(TranscriptLines.joined(["用", "Swift", "写"]), "用 Swift 写")
        XCTAssertEqual(TranscriptLines.joined(["read", "the", "文件"]), "read the 文件")
    }

    /// The hypothesis shape behind every sentence appearing twice: real durations, every
    /// timestamp at zero, so the whole of it lands on the window's first instant.
    func testAHypothesisWithNoTimestampsIsNotTimed() {
        let untimed = [word("涉及到", 0), word("这", 0), word("两", 0), word("中队", 0)]
        XCTAssertFalse(TranscriptLines.hasTimings(untimed))
        XCTAssertTrue(TranscriptLines.hasTimings([word("涉及到", 0), word("这", 1.2)]))
    }

    func testAnUntimedHypothesisNeverLandsBesideATimedOne() {
        let untimed = [word("涉及到", 0), word("这", 0), word("两", 0)]
        let timed = [word("涉及到", 22), word("这", 22.4), word("两", 22.8)]

        var heard = TranscriptLines.absorbing(untimed, into: [])
        heard = TranscriptLines.absorbing(timed, into: heard)

        XCTAssertEqual(heard.map(\.start), [22, 22.4, 22.8])
    }

    /// A recognizer revising words it already reported moves them; it doesn't leave a copy
    /// behind at the old timestamp.
    func testWordsReportedAgainAreMovedRatherThanDuplicated() {
        let first = [word("真正", 1), word("的", 1.4), word("能够", 1.8)]
        let revised = [word("能够", 1.9), word("透彻", 2.3)]

        let heard = TranscriptLines.absorbing(revised, into: TranscriptLines.absorbing(first, into: []))

        XCTAssertEqual(heard.map(\.text), ["真正", "的", "能够", "透彻"])
    }

    /// The whole point of folding hypotheses together: a later one that only describes the
    /// tail of the window must not throw away what came before it.
    func testALaterHypothesisKeepsWhatCameBeforeIt() {
        let opening = [word("真正", 1), word("的", 1.4)]
        let tail = [word("透彻", 20), word("的", 20.4), word("理解", 20.8)]

        let heard = TranscriptLines.absorbing(tail, into: TranscriptLines.absorbing(opening, into: []))

        XCTAssertEqual(heard.map(\.text), ["真正", "的", "透彻", "的", "理解"])
    }
}
