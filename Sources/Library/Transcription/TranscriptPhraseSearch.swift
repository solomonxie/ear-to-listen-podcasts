import Foundation

/// Finding a phrase inside the episode already open, against the lines held in memory —
/// no database, no index, no debounce-sized wait.
///
/// `TranscriptSearch` answers "which episode said this?" across the library; this answers
/// "where in *this* episode was it said?", which is the question with the audio playing.
///
/// Loose on purpose: the words typed have to appear in the line, in any order, each as a
/// substring — so "ferry dawn" finds "at dawn the ferries left". Recognisers mis-split
/// sentences, and hunting for the exact wording of something half-remembered is the part
/// that makes a transcript search useless.
enum TranscriptPhraseSearch {
    struct Hit: Identifiable, Hashable, Sendable {
        var start: Double
        var text: String

        var id: Double { start }
    }

    /// One letter matches every line in the episode, which is the same as no answer.
    static let minimumQueryLength = 2
    /// Past this the list is unreadable anyway — the answer is another word, which the
    /// count above the list says.
    static let limit = 50

    static func hits(for query: String, in lines: [TranscriptSegment], limit: Int = limit) -> [Hit] {
        let needles = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let longest = needles.max(by: { $0.count < $1.count }),
              longest.count >= minimumQueryLength
        else { return [] }

        var found: [Hit] = []
        for line in lines where !line.text.isEmpty {
            let haystack = line.text.lowercased()
            guard needles.allSatisfy({ haystack.contains($0) }) else { continue }
            found.append(Hit(start: line.start, text: line.text))
            if found.count >= limit { break }
        }
        return found
    }
}
