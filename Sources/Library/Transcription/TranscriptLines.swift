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
        // Anything the new hypothesis re-reports goes with it, timings and all — a
        // recognizer revising the same words at a new position must move them, not leave a
        // copy behind at the old one.
        return withoutRepeat(of: incoming, in: heard.filter { $0.start < first.start }) + incoming
    }

    /// Drops the tail of `heard` that `incoming` says again, matched on the words
    /// themselves: the same run at two timestamps is one revision, not two sentences.
    private static func withoutRepeat(
        of incoming: [RecognizedWord], in heard: [RecognizedWord]
    ) -> [RecognizedWord] {
        let spoken = incoming.map(\.text)
        for overlap in stride(from: min(heard.count, spoken.count), to: 0, by: -1) {
            if heard.suffix(overlap).map(\.text) == Array(spoken.prefix(overlap)) {
                return Array(heard.dropLast(overlap))
            }
        }
        return heard
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

    /// Whether the recognizer gave usable word timings.
    ///
    /// One non-zero duration is not enough. Apple's on-device recognizer routinely returns
    /// a whole hypothesis with every `timestamp` at zero and real durations — which places
    /// every word of it at the window's first instant. Read as timed, it gets folded in
    /// beside the properly timed hypothesis of the same audio, and the sentence appears
    /// twice: once at the top of the window, once where it was actually said. Past the
    /// first word, a real hypothesis always moves.
    static func hasTimings(_ words: [RecognizedWord]) -> Bool {
        guard let first = words.first else { return false }
        guard words.count > 1 else { return first.start > 0 || first.duration > 0 }
        return words.dropFirst().contains { $0.start > 0 }
    }

    /// Readable chunks out of untimed words: break on sentence ends, otherwise on length.
    static func phrases(in words: [RecognizedWord]) -> [String] {
        var out: [String] = []
        var pending: [String] = []

        func flush() {
            let text = joined(pending).trimmingCharacters(in: .whitespaces)
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

    /// Joins tokens the way the language writes them. Recognizers hand back one token at a
    /// time whatever the language, and a space between each is right for English and wrong
    /// for Chinese, Japanese and Korean — where it turns a sentence into loose characters
    /// with gaps down the middle of every word.
    static func joined(_ tokens: [String]) -> String {
        tokens.reduce(into: "") { text, token in
            guard !text.isEmpty else { return text = token }
            // Only between two of them: a Latin word in a Chinese sentence still reads
            // better with air around it, and an English transcript is untouched.
            let needsSpace = !(isScriptWithoutSpaces(text.last) && isScriptWithoutSpaces(token.first))
            text += (needsSpace ? " " : "") + token
        }
    }

    /// CJK ideographs, kana, Hangul and their full-width punctuation — the scripts that
    /// don't put spaces between words.
    private static func isScriptWithoutSpaces(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// One line out of consecutive words, or nothing when they're all whitespace.
    private static func line(
        from words: [RecognizedWord], startOffset: Double, engine: String
    ) -> TranscriptSegment? {
        let text = joined(words.map(\.text)).trimmingCharacters(in: .whitespaces)
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
