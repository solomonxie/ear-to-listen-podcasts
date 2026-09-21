import Foundation
import GRDB

/// Searching what was *said*, not what things are called.
///
/// The rest of search matches names — an episode's title, a speaker, a collection — which
/// is everything the library knows about a file except the part that matters most. A
/// transcript is the only place "the bit about the ferries at dawn" exists, and finding it
/// is the whole point of having transcribed anything.
///
/// It runs separately from `LibrarySearch`, and its hits are shown last, because the two
/// answer different questions: names are what you search when you know what you're after,
/// speech is what you search when you don't. A line from the middle of an episode
/// outranking the episode you actually named would be wrong every time.
///
/// **Substring match in SQLite, not a search index.** Transcripts are JSON blobs in one
/// column; `instr` over them is something the database can do across a whole library in
/// one statement, with nothing to keep up to date. It costs a scan — capped here by how
/// many rows are decoded — and the day that isn't fast enough, an FTS5 table is the answer
/// (it's in the backlog).
struct TranscriptSearch {
    /// One line of speech that matched, with enough either side of it to read.
    struct Match: Identifiable, Hashable, Sendable {
        var trackID: String
        var start: Double
        var text: String

        var id: String { "\(trackID)@\(start)" }
    }

    /// Transcripts opened per query. They're decoded in full, so this is the real cost.
    private static let transcriptLimit = 30
    /// Per episode, so one repetitive episode can't fill the section.
    private static let linesPerTranscript = 3
    static let matchLimit = 30

    let dbQueue: DatabaseQueue

    /// Nothing shorter: one or two letters match every transcript in the library, and the
    /// scan is the expensive half of search.
    static let minimumQueryLength = 2

    func matches(for query: String, limit: Int = matchLimit) throws -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= Self.minimumQueryLength else { return [] }

        var found: [Match] = []
        for row in try candidates(needle: needle) {
            guard let segments = try? JSONDecoder().decode(
                [TranscriptSegment].self, from: Data(row.segmentsJSON.utf8)
            ) else { continue }
            let lines = TranscriptSegment.normalized(segments).filter { !$0.text.isEmpty }
            let hits = lines.indices.filter { lines[$0].text.lowercased().contains(needle) }
            for index in hits.prefix(Self.linesPerTranscript) {
                found.append(
                    Match(
                        trackID: row.trackID, start: lines[index].start,
                        text: Self.excerpt(around: index, in: lines)
                    )
                )
                if found.count >= limit { return found }
            }
        }
        return found
    }

    /// The transcripts that hold the words at all, the ones saying them most first —
    /// ordering in SQL so the cap drops the least relevant rows rather than arbitrary ones.
    private func candidates(needle: String) throws -> [(trackID: String, segmentsJSON: String)] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT trackID, segmentsJSON FROM transcripts
                WHERE instr(lower(segmentsJSON), ?) > 0
                ORDER BY length(segmentsJSON) - length(replace(lower(segmentsJSON), ?, '')) DESC
                LIMIT \(Self.transcriptLimit)
                """,
                arguments: [needle, needle]
            ).compactMap { row -> (trackID: String, segmentsJSON: String)? in
                guard let trackID: String = row["trackID"], let json: String = row["segmentsJSON"] else {
                    return nil
                }
                return (trackID, json)
            }
        }
    }

    /// The matching line with its neighbours. One line is a few seconds of speech — too
    /// little to recognise the moment from.
    static func excerpt(around index: Int, in lines: [TranscriptSegment], reach: Int = 1) -> String {
        let range = max(0, index - reach)...min(lines.count - 1, index + reach)
        return TranscriptLines.joined(lines[range].map(\.text))
    }
}
