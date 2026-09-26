import Foundation
import GRDB

/// One AI pass over an episode's transcript that answers the two questions a library this
/// size actually gets asked: *what is this episode*, and *what does it keep talking
/// about*. Both come from one call — they read the same transcript, and a second call
/// would pay for the same tokens twice to ask a smaller question.
///
/// **The transcript goes in with its timestamps.** That's the difference between a
/// summary and a useful one: the model can only say "at 12:14 they get to the point" if
/// it was told when things were said, and those markers are what the card turns into
/// taps that play from there.
///
/// **The counts are not the model's.** It's asked for names and terms, not for how often
/// each was said — a model asked to count guesses, and a frequency ranking built on
/// guesses ranks nothing. The app counts them itself against the transcript.
struct EpisodeSummarizer {
    struct Result {
        var summary: String
        /// Term → times it's actually said in this episode.
        var terms: [String: Int]
    }

    struct UnreadableSummaryError: Error, LocalizedError {
        var errorDescription: String? { "The AI response wasn't in a form the app could read. Try again." }
    }

    struct NoTranscriptError: Error, LocalizedError {
        var errorDescription: String? {
            "Transcribe this episode first — a summary is written from what was said, not from the file name."
        }
    }

    /// How much transcript one summary is allowed to send. What goes over is sampled
    /// across the whole episode rather than cut off at the front, for the same reason
    /// `EpisodeMetadataSuggester` samples: the end of an episode is where it concludes.
    private static let characterBudget = 28_000

    /// A paragraph, eight timed points and a list of terms don't fit in the router's
    /// default. They didn't before either — the reply stopped mid-object and arrived as
    /// "the response wasn't in a form the app could read", which is a truncation wearing
    /// a parser's error message.
    private static let maxReplyTokens = 1_600

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    /// A summary needs words, not a complete transcript: a half-transcribed episode still
    /// summarises the half it has, and says so by the times its points carry. Only "no
    /// transcript at all" is a reason to refuse.
    /// Asked of the row, not of its contents — a transcript with lines in it is the
    /// answer, and reading the lines to count them is a page's worth of JSON decoded for
    /// one bit. Says nothing about how complete it is; `EpisodeMetadataSuggester.readiness`
    /// is the one that needs the spans.
    func hasTranscript(trackID: String) -> Bool {
        (try? TranscriptStore(dbQueue: dbQueue).exists(trackID: trackID)) ?? false
    }

    /// Runs the pass and stores both halves. Returns the summary text so the card can
    /// show it without re-reading the row.
    @discardableResult
    func run(track: Track) async throws -> Result {
        let result = try await analyze(track: track)
        try TrackStore(dbQueue: dbQueue).setSummary(id: track.id, summary: result.summary)
        try TermStore(dbQueue: dbQueue).setTerms(result.terms, forTrack: track.id)
        return result
    }

    func analyze(track: Track) async throws -> Result {
        let lines = segments(trackID: track.id)
        guard !lines.isEmpty else { throw NoTranscriptError() }

        let prompt = """
        You are summarising one podcast episode for the person who owns it.

        Title: \(track.title)
        Duration: \(track.durationMs.map { "\($0 / 60000) minutes" } ?? "unknown")
        \(languageInstruction(for: track))

        Transcript, one line per entry, prefixed with the time it was said:
        \(transcriptBlock(lines))

        Write:
        - "brief": two or three sentences saying what this episode is and who it's for.
        - "points": the moments worth going back to, in the order they happen, at most
          eight. Each carries the time it starts, copied from the transcript prefixes, in
          the same m:ss form. One sentence each, saying what was said — not "they discuss
          X".
        - "conclusion": one or two sentences, only if the episode actually lands
          somewhere. Null if it just ends.
        - "terms": the names and terms this episode is about — people, places,
          organisations, books, products, technical terms. Write each exactly as it is
          said in the transcript — never translated, never transliterated — and leave out
          anything that isn't a name or a term of art. At most 25.

        Strict JSON only, no other text:
        {"brief": string, "points": [{"time": string, "text": string}],
         "conclusion": string|null, "terms": [string]}
        """

        let content = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue,
            maxTokens: Self.maxReplyTokens
        )
        let spoken = lines.map(\.text).joined(separator: " ")
        let draft = EpisodeMetadataSuggester.jsonObject(in: content)
            .flatMap { try? JSONDecoder().decode(EpisodeSummary.Draft.self, from: Data($0.utf8)) }
        if let draft, case let summary = EpisodeSummary.text(from: draft), !summary.isEmpty {
            return Result(summary: summary, terms: Self.counts(of: draft.terms ?? [], in: spoken))
        }
        // It answered in prose instead. That's still the summary — it just costs the
        // times and the terms, and throwing it away would cost the whole call.
        if let prose = EpisodeSummary.prose(in: content) {
            return Result(summary: prose, terms: [:])
        }
        throw UnreadableSummaryError()
    }

    /// How often each term is actually said. A term the model returned but that never
    /// appears verbatim still counts once — it paraphrased something that's in there, and
    /// dropping it would quietly edit the model's answer.
    static func counts(of terms: [String], in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for term in terms.map({ $0.trimmed }) where !term.isEmpty {
            counts[term] = max(1, occurrences(of: term, in: text))
        }
        return counts
    }

    /// Whole words only. Without the boundaries "AI" matches the middle of "said" and the
    /// chart's tallest bar is a typo.
    static func occurrences(of term: String, in text: String) -> Int {
        guard let regex = wordMatcher(for: term) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
    }

    /// Where a term is said, line by line — what the term page lists so a mention can be
    /// played rather than only counted. One entry per line, not per match: two mentions in
    /// the same sentence are one place to start listening.
    static func mentions(of term: String, in segments: [TranscriptSegment]) -> [TermMention] {
        guard wordMatcher(for: term) != nil else { return [] }
        return segments.compactMap { segment in
            let text = segment.text.trimmed
            guard !text.isEmpty, occurrences(of: term, in: text) > 0 else { return nil }
            return TermMention(start: segment.start, text: text)
        }
    }

    /// Whole-word matching where words have edges, plain matching where they don't.
    ///
    /// `\b` is a boundary between a word character and a non-word one — which in Chinese,
    /// Japanese or Thai never happens mid-sentence, because every neighbouring character
    /// is a word character too. `\b人工智能\b` therefore matched nothing at all in the
    /// sentence it was quoted from, and every CJK term came out counted 1 with its
    /// mentions listed as "not said in those words". The boundary is applied per end, so
    /// a mixed term like "OpenAI 的模型" still anchors the side that can be anchored.
    private static func wordMatcher(for term: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let lead = hasWordEdge(term.first) ? "\\b" : ""
        let trail = hasWordEdge(term.last) ? "\\b" : ""
        return try? NSRegularExpression(pattern: lead + escaped + trail, options: [.caseInsensitive])
    }

    /// Whether a boundary either side of this character means anything — false for the
    /// scripts written without spaces between words.
    static func hasWordEdge(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        let spaceless: [ClosedRange<UInt32>] = [
            0x3040...0x30FF,     // Hiragana, Katakana
            0x3400...0x4DBF,     // CJK ext A
            0x4E00...0x9FFF,     // CJK unified
            0xF900...0xFAFF,     // CJK compatibility
            0x0E00...0x0E7F,     // Thai
            0x1000...0x109F,     // Myanmar
            0x1780...0x17FF,     // Khmer
            0x20000...0x3FFFF,   // CJK ext B and beyond
        ]
        return !spaceless.contains { $0.contains(scalar.value) }
    }

    /// The episode is written up in the language it's spoken in, not the language these
    /// instructions happen to be written in. A Mandarin episode summarised in English is
    /// a translation nobody asked for — and one that can't be checked against the
    /// transcript sitting under it on the same page.
    ///
    /// Where no language has been set anywhere, the transcript itself is the instruction:
    /// it's the only evidence there is, and it's right in front of the model.
    private func languageInstruction(for track: Track) -> String {
        let libraryStore = LibraryStore(dbQueue: dbQueue)
        let resolved = TranscriptRunner.resolveLanguage(
            track: track,
            album: track.albumID.flatMap { (try? libraryStore.album(id: $0)) ?? nil },
            artist: track.artistID.flatMap { (try? libraryStore.artist(id: $0)) ?? nil }
        )
        guard let name = resolved.flatMap({ Self.languageName(forIdentifier: $0.identifier) }) else {
            return "Write in the language the transcript below is in, whatever language these instructions are in."
        }
        return "Write in \(name) — the language this episode is spoken in — whatever language these instructions are in."
    }

    /// Named in English because that's the language the prompt is written in: a model
    /// reading "Write in Mandarin Chinese" knows what to do with it, where a bare `zh-CN`
    /// is a code it has to guess at.
    static func languageName(forIdentifier identifier: String) -> String? {
        Locale(identifier: "en_US").localizedString(forIdentifier: identifier)?.nilIfEmpty ?? identifier.nilIfEmpty
    }

    private func segments(trackID: String) -> [TranscriptSegment] {
        ((try? TranscriptStore(dbQueue: dbQueue).find(trackID: trackID)) ?? [])
            .filter { !$0.text.trimmed.isEmpty }
    }

    /// `12:14 what was said`, one line each, thinned evenly when the episode runs longer
    /// than the budget — dropping whole lines rather than cutting the text, so every line
    /// that does go still has the time that makes it quotable.
    private func transcriptBlock(_ lines: [TranscriptSegment]) -> String {
        let kept = Self.thinned(lines, budget: Self.characterBudget)
        return kept
            .map { "\(Scrubber.formatted($0.start)) \($0.text.trimmed)" }
            .joined(separator: "\n")
    }

    static func thinned(_ lines: [TranscriptSegment], budget: Int) -> [TranscriptSegment] {
        let total = lines.reduce(0) { $0 + $1.text.count + 8 }
        guard total > budget, !lines.isEmpty else { return lines }
        let step = max(2, Int((Double(total) / Double(budget)).rounded(.up)))
        // Every nth line, plus the last one: an episode's close is the part a summary is
        // most often wrong about, and striding lands short of it.
        var kept = lines.enumerated().filter { $0.offset % step == 0 }.map(\.element)
        if let last = lines.last, kept.last?.start != last.start { kept.append(last) }
        return kept
    }
}
