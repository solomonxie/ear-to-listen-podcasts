import Foundation
import GRDB

/// A name or term an episode actually talks about — a person, a place, a book, a piece of
/// jargon. Pulled out of the transcript by the same AI pass that writes the summary.
///
/// Not a `Topic`. A topic is what a *collection* is about and is typed by hand; a term is
/// what one episode *mentions*, and there are dozens per episode. Keeping them apart is
/// what lets terms be counted and ranked without a hand-made tag list turning into a
/// frequency table nobody curated.
struct Term: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "terms"

    var id: String
    var name: String
}

/// How often one episode mentions one term. The count is the app's own, taken by scanning
/// the transcript — a model asked for counts guesses them, and a ranking built on guesses
/// is a ranking of nothing.
struct TrackTerm: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "trackTerms"

    var trackID: String
    var termID: String
    var mentions: Int
}

/// A term with however many mentions the view is asking about — one episode's, an album's,
/// or the whole library's.
struct TermCount: Identifiable, Hashable {
    var term: Term
    var mentions: Int
    /// How many episodes it was counted across. 1 on an episode page, more elsewhere.
    var episodes: Int = 1

    var id: String { term.id }
    var name: String { term.name }
}

/// One place a term is said: the line it's in, and when that line starts. Derived from
/// the transcript on demand rather than stored — the count is what a ranking needs, and
/// keeping a row per sentence would be a second copy of the transcript.
struct TermMention: Identifiable, Hashable {
    var start: Double
    var text: String

    var id: Double { start }
}
