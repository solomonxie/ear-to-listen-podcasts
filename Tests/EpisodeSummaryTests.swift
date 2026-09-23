import XCTest
@testable import EarToListen

/// The summary's one piece of markup is `[12:34]`, and everything the card can do with a
/// summary depends on it surviving the round trip from the model's JSON to editable text
/// and back into links.
final class EpisodeSummaryTests: XCTestCase {
    func testMarkersReadAsSeconds() {
        XCTAssertEqual(EpisodeSummary.seconds(inMarker: "12:34"), 754)
        XCTAssertEqual(EpisodeSummary.seconds(inMarker: "1:02:03"), 3723)
        XCTAssertNil(EpisodeSummary.seconds(inMarker: "later"))
        XCTAssertNil(EpisodeSummary.seconds(inMarker: "12"))
    }

    func testADraftBecomesEditableTextWithItsTimesKept() {
        let draft = EpisodeSummary.Draft(
            brief: "  Two sentences about sleep.  ",
            points: [
                .init(time: "2:05", text: "Light in the morning."),
                .init(time: nil, text: "A point with no time still earns its line."),
                .init(time: "41:10", text: "  "),
            ],
            conclusion: "Go outside.",
            terms: ["melatonin"]
        )

        XCTAssertEqual(
            EpisodeSummary.text(from: draft),
            """
            Two sentences about sleep.

            • [2:05] Light in the morning.
            • A point with no time still earns its line.

            Go outside.
            """
        )
    }

    /// A point whose text is blank is dropped rather than left as an empty bullet, and a
    /// draft with nothing usable in it produces nothing — the caller treats that as a
    /// failed pass rather than storing an empty summary.
    func testAnEmptyDraftProducesNoSummary() {
        XCTAssertTrue(EpisodeSummary.text(from: EpisodeSummary.Draft()).isEmpty)
    }

    /// The near-misses a model actually sends back. Each of these used to throw the whole
    /// reply away — which is the most expensive call this app makes.
    func testADraftSurvivesTheShapesModelsActuallySend() throws {
        let json = """
        {"summary": "What this is.",
         "points": [{"time": 125, "text": "Seconds, not a stamp."},
                    "2:05 A bare string point.",
                    {"start": "10:00", "point": "Other key names."}],
         "terms": [{"name": "melatonin"}, "cortisol"]}
        """

        let draft = try JSONDecoder().decode(EpisodeSummary.Draft.self, from: Data(json.utf8))

        XCTAssertEqual(draft.brief, "What this is.")
        XCTAssertEqual(draft.terms, ["melatonin", "cortisol"])
        XCTAssertEqual(draft.points?.count, 3)
        XCTAssertEqual(
            EpisodeSummary.text(from: draft),
            """
            What this is.

            • [2:05] Seconds, not a stamp.
            • [2:05] A bare string point.
            • [10:00] Other key names.
            """
        )
    }

    /// A model that drops the format and answers in prose has still written the summary.
    func testProseIsKeptButJsonIsNot() {
        XCTAssertEqual(
            EpisodeSummary.prose(in: "```\nA long enough answer about what this episode is and why.\n```"),
            "A long enough answer about what this episode is and why."
        )
        XCTAssertNil(EpisodeSummary.prose(in: "{\"brief\": \"half an obj"))
        XCTAssertNil(EpisodeSummary.prose(in: "ok"))
    }

    func testOnlyRealTimesBecomeLinks() {
        let attributed = EpisodeSummary.attributed("Starts at [2:05], and again at [99], see [1:02:03].")
        let links = attributed.runs.compactMap(\.link)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(EpisodeSummary.seconds(inURL: links[0]), 125)
        XCTAssertEqual(EpisodeSummary.seconds(inURL: links[1]), 3723)
        // The brackets go; the time itself stays readable text.
        XCTAssertTrue(String(attributed.characters).contains("Starts at 2:05,"))
    }
}

/// The counts behind the Terms chart are the app's, not the model's — which only works if
/// counting is actually right.
final class EpisodeSummarizerCountingTests: XCTestCase {
    func testTermsAreCountedAsWholeWords() {
        let text = "They said AI twice: AI and ai. Said again, said."

        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "AI", in: text), 3)
        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "said", in: text), 3)
        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "sleep", in: text), 0)
    }

    /// Chinese, Japanese and Thai write without spaces, so there is no word boundary to
    /// anchor to — `\\b人工智能\\b` matched nothing in the very sentence it was quoted from.
    func testTermsInSpacelessScriptsAreCounted() {
        let text = "他说人工智能会改变世界，人工智能很强。"

        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "人工智能", in: text), 2)
        XCTAssertEqual(
            EpisodeSummarizer.mentions(of: "人工智能", in: [TranscriptSegment(start: 3, text: text)]).count,
            1
        )
        XCTAssertFalse(EpisodeSummarizer.hasWordEdge("人"))
        XCTAssertTrue(EpisodeSummarizer.hasWordEdge("A"))
    }

    func testMultiWordTermsAndPunctuationCountToo() {
        let text = "Andrew Huberman opened. Later, Andrew Huberman's lab — Huberman again."

        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "Andrew Huberman", in: text), 2)
        XCTAssertEqual(EpisodeSummarizer.occurrences(of: "Huberman", in: text), 3)
    }

    /// A term the model returned but paraphrased still counts once: dropping it would be
    /// the app quietly editing the model's answer.
    func testATermThatIsNeverSaidVerbatimStillCountsOnce() {
        XCTAssertEqual(EpisodeSummarizer.counts(of: ["circadian rhythm"], in: "the body clock"), ["circadian rhythm": 1])
    }

    /// The write-up goes out in the episode's own language, which means naming that
    /// language in the prompt in a form a model can act on.
    func testLanguagesAreNamedInEnglishForThePrompt() {
        XCTAssertEqual(EpisodeSummarizer.languageName(forIdentifier: "zh-CN"), "Chinese (China mainland)")
        XCTAssertEqual(EpisodeSummarizer.languageName(forIdentifier: "en-US"), "English (United States)")
        // Not a locale anyone recognises — passed through rather than dropped, since it's
        // still more than the model would otherwise know.
        XCTAssertEqual(EpisodeSummarizer.languageName(forIdentifier: "xx-YY"), "xx-YY")
    }

    /// The term page plays a mention, so each one has to carry the second it starts and
    /// they have to arrive in the order they're said.
    func testMentionsCarryTheirTimeAndStayInOrder() {
        let lines = [
            TranscriptSegment(start: 12, text: "Melatonin is not a sleeping pill."),
            TranscriptSegment(start: 30, text: "Nothing about it here."),
            TranscriptSegment(start: 61.5, text: "Which is why melatonin, taken late, backfires."),
            TranscriptSegment(start: 90, text: "   "),
        ]

        let found = EpisodeSummarizer.mentions(of: "melatonin", in: lines)

        XCTAssertEqual(found.map(\.start), [12, 61.5])
        XCTAssertEqual(found.first?.text, "Melatonin is not a sleeping pill.")
    }

    /// Two mentions in one sentence are one place to start listening, not two rows.
    func testALineSaidTwiceIsOneMention() {
        let lines = [TranscriptSegment(start: 5, text: "Sleep, and more sleep.")]

        XCTAssertEqual(EpisodeSummarizer.mentions(of: "sleep", in: lines).count, 1)
    }

    /// Thinning drops whole lines so every line that survives keeps the timestamp that
    /// makes it quotable — and the last line always survives, because how an episode ends
    /// is what a summary gets wrong when it doesn't see it.
    func testThinningKeepsTheEndOfTheEpisode() {
        let lines = (0..<200).map { TranscriptSegment(start: Double($0) * 10, text: String(repeating: "word ", count: 20)) }

        let kept = EpisodeSummarizer.thinned(lines, budget: 2_000)

        XCTAssertLessThan(kept.count, lines.count)
        XCTAssertEqual(kept.first?.start, lines.first?.start)
        XCTAssertEqual(kept.last?.start, lines.last?.start)
    }
}
