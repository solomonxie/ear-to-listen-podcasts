import Foundation

/// One word as any recognizer might hand it over, with times relative to the window it
/// came from. Deliberately not `SFTranscriptionSegment`: grouping words into readable
/// lines is the part of transcription worth porting, and it shouldn't need Apple's
/// `Speech` framework to compile or to test.
struct RecognizedWord: Sendable, Equatable {
    var text: String
    var start: Double
    var duration: Double

    var end: Double { start + duration }

    var endsSentence: Bool {
        text.last.map { ".!?。！？；;".contains($0) } ?? false
    }
}

/// What a recognizer has made out so far, split by whether it can still change.
///
/// The two halves are rendered very differently, which is the whole point. Settled lines
/// carry real timestamps, hold still, and can be tapped or corrected. The volatile tail
/// is only text: every word in it may still be rewritten, so it gets one identity in the
/// view and no timestamps it can't honour.
struct TranscriptDraft: Sendable, Equatable {
    var settled: [TranscriptSegment] = []
    /// Split into phrases for reading, but they stand or fall together.
    var volatile: [String] = []

    var isEmpty: Bool { settled.isEmpty && volatile.isEmpty }
}

/// Turns loose words into lyric-style lines, and decides which of them have stopped moving.
enum TranscriptLines {
    /// Phrases are capped at this many words when there's nothing else to break on, so a
    /// long unpunctuated run still reads as lines rather than a paragraph.
    static let maximumWordsPerPhrase = 9

    /// Recognizers hand back individual words, not sentences. Lyric-style highlighting
    /// needs lines, so words are grouped until a sentence ends, the speaker pauses, or the
    /// line simply gets too long to highlight as one unit.
    static func grouped(
        _ words: [RecognizedWord],
        startOffset: Double,
        engine: String,
        maxLineSeconds: Double = 12,
        pauseSeconds: Double = 0.7
    ) -> [TranscriptSegment] {
        var lines: [TranscriptSegment] = []
        var pending: [RecognizedWord] = []

        func flush() {
            if let line = line(from: pending, startOffset: startOffset, engine: engine) {
                lines.append(line)
            }
            pending = []
        }

        for (index, word) in words.enumerated() {
            pending.append(word)
            let next = index + 1 < words.count ? words[index + 1] : nil
            let pausesAfter = next.map { $0.start - word.end >= pauseSeconds } ?? true
            let tooLong = word.end - (pending.first?.start ?? word.start) >= maxLineSeconds
            let tooMany = pending.count >= maximumWordsPerPhrase * 2
            if word.endsSentence || pausesAfter || tooLong || tooMany || next == nil { flush() }
        }
        flush()
        return lines
    }

    /// Folds a fresh hypothesis into everything the recognizer has already said about
    /// this window.
    ///
    /// Recognizers don't always revise from the top. On long-form audio Apple's breaks the
    /// window into utterances and starts a new hypothesis at each one, so the result that
    /// arrives last can describe only the final few seconds — take it as *the* answer and
    /// the rest of the window is silently thrown away, then recorded as silence and never
    /// looked at again. A hypothesis speaks for its own span onwards; whatever was
    /// reported before it and not mentioned again still stands.
    ///
    /// Untimed hypotheses are ignored: they carry nothing that could be placed on the
    /// episode's timeline, and folding them in would strand text at the window's start.
    static func absorbing(_ incoming: [RecognizedWord], into heard: [RecognizedWord]) -> [RecognizedWord] {
        guard hasTimings(incoming), let first = incoming.first else { return heard }
        return heard.filter { $0.start < first.start } + incoming
    }

    /// Splits a hypothesis into what's stopped moving and what hasn't.
    ///
    /// Partial results routinely arrive with **no word timings at all** — every word
    /// reporting zero. Pause and line-length are both timing tests, so with nothing to
    /// break on, a whole window used to collapse into a single line that visibly rewrote
    /// itself word by word. When there are no timings, nothing can be settled and the text
    /// is broken on punctuation and length instead, so it at least reads as phrases.
    static func split(
        _ words: [RecognizedWord],
        startOffset: Double,
        engine: String,
        stabilitySeconds: Double = 2,
        maxLineSeconds: Double = 12,
        pauseSeconds: Double = 0.7
    ) -> TranscriptDraft {
        guard !words.isEmpty else { return TranscriptDraft() }
        guard hasTimings(words) else {
            return TranscriptDraft(settled: [], volatile: phrases(in: words))
        }

        let leadingEdge = words.map(\.end).max() ?? 0
        let settledBefore = leadingEdge - stabilitySeconds
        var settledCount = words.lastIndex { $0.end <= settledBefore }.map { $0 + 1 } ?? 0
        // A closed sentence is the strongest stability signal there is, even a fresh one.
        if let lastSentence = words.lastIndex(where: \.endsSentence) {
            settledCount = max(settledCount, lastSentence + 1)
        }

        return TranscriptDraft(
            settled: grouped(
                Array(words.prefix(settledCount)), startOffset: startOffset, engine: engine,
                maxLineSeconds: maxLineSeconds, pauseSeconds: pauseSeconds
            ),
            volatile: phrases(in: Array(words.dropFirst(settledCount)))
        )
    }

    /// Whether the recognizer gave any usable word timings. A hypothesis where every word
    /// sits at zero has none — which is the normal shape of a partial result.
    static func hasTimings(_ words: [RecognizedWord]) -> Bool {
        words.contains { $0.start > 0 || $0.duration > 0 }
    }

    /// Readable chunks out of untimed words: break on sentence ends, otherwise on length.
    static func phrases(in words: [RecognizedWord]) -> [String] {
        var out: [String] = []
        var pending: [String] = []

        func flush() {
            let text = pending.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { out.append(text) }
            pending = []
        }

        for word in words {
            pending.append(word.text)
            if word.endsSentence || pending.count >= maximumWordsPerPhrase { flush() }
        }
        flush()
        return out
    }

    /// One line out of consecutive words, or nothing when they're all whitespace.
    private static func line(
        from words: [RecognizedWord], startOffset: Double, engine: String
    ) -> TranscriptSegment? {
        let text = words.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let first = words.first else { return nil }
        let end = words.map(\.end).max() ?? first.start
        return TranscriptSegment(
            start: startOffset + first.start,
            end: startOffset + max(end, first.start),
            text: text,
            engine: engine
        )
    }
}
