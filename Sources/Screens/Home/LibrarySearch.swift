import Foundation

/// Searching the library, done once per query instead of once per SwiftUI body pass.
///
/// The old version was six computed properties on the view, each rescanning a whole
/// collection with `localizedCaseInsensitiveContains`. SwiftUI evaluates those every time
/// it builds the body, and `hasResults` touched all six before the sections touched them
/// again — so a library of 5,000 episodes did ~20,000 locale-aware Unicode comparisons
/// per keystroke, on the main thread, while the keyboard waited.
///
/// Two changes make it cheap: the haystacks are folded to lowercase **once** when the
/// library loads rather than per comparison, and matching is a plain substring check on
/// the folded text. That gives up locale-specific collation, which matters far less here
/// than the search staying ahead of typing — and case-folding still covers the ASCII case
/// everyone actually types.
///
/// `Index` and `Results` are `Sendable` so the scan itself can run off the main actor —
/// debouncing keeps it from running often, but a library big enough still has no business
/// doing the work on the thread the keyboard draws on.
struct LibrarySearch {
    struct Index: Sendable {
        var speakers: [(item: Artist, haystack: String)] = []
        var albums: [(item: Album, haystack: String)] = []
        var playlists: [(item: Playlist, haystack: String)] = []
        var topics: [(item: Topic, haystack: String)] = []
        /// Title *and* path: with a folder of files sharing one embedded title tag, the
        /// filename is often the only thing the listener can search for.
        var tracks: [(item: Track, haystack: String)] = []
        /// The marks, by what was typed into them and what was said at them.
        var notes: [(item: Bookmark, haystack: String)] = []
    }

    struct Results: Sendable {
        var speakers: [Artist] = []
        var albums: [Album] = []
        var playlists: [Playlist] = []
        var topics: [Topic] = []
        var tracks: [Track] = []
        var notes: [Bookmark] = []
        /// How many episodes matched before `episodeLimit` cut the list down.
        var totalTrackMatches = 0

        var isEmpty: Bool {
            speakers.isEmpty && albums.isEmpty && playlists.isEmpty
                && topics.isEmpty && tracks.isEmpty && notes.isEmpty
        }
    }

    /// A one-letter query matches nearly every episode, and every row returned is a row
    /// SwiftUI builds. Past this many there's nothing to read anyway — the answer is to
    /// type another letter, which the count in the header says out loud.
    static let episodeLimit = 200

    static func fold(_ text: String) -> String { text.lowercased() }

    /// Everything the library holds in words, folded once.
    ///
    /// Not just names: a speaker's bio, a collection's notes, what someone typed on a
    /// bookmark. The listener wrote all of it *here*, and a search box that can't find
    /// what you yourself typed into the app is the most annoying kind of search box.
    /// Speech is the one thing not in here — transcripts are megabytes and live in the
    /// database, so `TranscriptSearch` goes to them instead.
    static func index(
        speakers: [Artist], albums: [Album], playlists: [Playlist], topics: [Topic],
        tracks: [Track], notes: [Bookmark] = []
    ) -> Index {
        Index(
            speakers: speakers.map {
                ($0, fold(joined($0.name, $0.bio, $0.knownFor, $0.background, $0.profile, $0.link)))
            },
            albums: albums.map {
                ($0, fold(joined($0.name, $0.notes, $0.profile, $0.year.map(String.init))))
            },
            playlists: playlists.map { ($0, fold($0.name)) },
            topics: topics.map { ($0, fold($0.name)) },
            tracks: tracks.map {
                ($0, fold(joined($0.title, $0.filePath, $0.notes, $0.year.map(String.init))))
            },
            notes: notes.map { ($0, fold(joined($0.note, $0.tags, $0.transcriptText))) }
        )
    }

    private static func joined(_ parts: String?...) -> String {
        parts.compactMap { $0?.nilIfEmpty }.joined(separator: "\n")
    }

    /// Off the main actor, at user-initiated priority — the caller awaits it, so a slow
    /// scan delays the results rather than the typing.
    static func run(_ query: String, in index: Index) async -> Results {
        await Task.detached(priority: .userInitiated) { runSync(query, in: index) }.value
    }

    /// The scan itself. Separated so tests can call it straight, without a hop.
    static func runSync(_ query: String, in index: Index) -> Results {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return Results() }

        func matches<T>(_ entries: [(item: T, haystack: String)]) -> [T] {
            entries.filter { $0.haystack.contains(needle) }.map(\.item)
        }

        var results = Results(
            speakers: matches(index.speakers),
            albums: matches(index.albums),
            playlists: matches(index.playlists),
            topics: matches(index.topics)
        )
        let tracks = matches(index.tracks)
        results.totalTrackMatches = tracks.count
        results.tracks = Array(tracks.prefix(episodeLimit))
        results.notes = Array(matches(index.notes).prefix(episodeLimit))
        return results
    }
}
