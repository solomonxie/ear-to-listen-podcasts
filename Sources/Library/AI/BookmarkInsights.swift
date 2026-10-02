import Foundation
import GRDB

/// One AI read across every saved moment — the marks, their notes and tags, and the line
/// being spoken at each — asked what they add up to: the themes the listener keeps
/// stopping for, what connects episodes they'd never have put side by side, and what to
/// listen to or think about next.
///
/// **Every mark, not Home's thirty.** Home reads `BookmarkStore.recent`; insights about
/// "my bookmarks" drawn from the newest fraction of them would be about last week.
/// What goes over the budget is the oldest, dropped whole — a mark is only useful with
/// its episode and its note together.
///
/// **Kept until asked again.** The last result is stored with its date and the mark count
/// it was written from, so reopening the sheet costs nothing, and the sheet can say when
/// the marks have moved on since.
struct BookmarkInsights {
    struct Saved: Codable, Equatable {
        var text: String
        var generatedAt: Date
        var markCount: Int
    }

    struct NoBookmarksError: Error, LocalizedError {
        var errorDescription: String? { "Mark a few moments while listening first — insights are written from them." }
    }

    struct EmptyReplyError: Error, LocalizedError {
        var errorDescription: String? { "The AI sent back nothing to show. Try again." }
    }

    /// Enough for a few hundred annotated marks; a library past that is summarised from
    /// its most recent ones.
    static let characterBudget = 24_000
    private static let maxReplyTokens = 1_400
    private static let savedDefaultsKey = "bookmarkInsights.saved"

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue
    /// The episodes to read marks from — one on an episode page, an album's or a speaker's
    /// on theirs. Nil reads every mark.
    var trackIDs: Set<String>? = nil

    /// Kept per scope, so an episode's insights don't overwrite an album's.
    private var savedKey: String {
        guard let trackIDs else { return Self.savedDefaultsKey }
        return Self.savedDefaultsKey + "." + String(LibraryArt.stableHash(trackIDs.sorted().joined(separator: ",")))
    }

    var saved: Saved? {
        get {
            UserDefaults.standard.data(forKey: savedKey)
                .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: savedKey)
        }
    }

    func markCount() -> Int {
        (try? scopedMarks().count) ?? 0
    }

    private func scopedMarks() throws -> [Bookmark] {
        let marks = try BookmarkStore(dbQueue: dbQueue).all()
        guard let trackIDs else { return marks }
        return marks.filter { trackIDs.contains($0.trackID) }
    }

    @discardableResult
    func run() async throws -> Saved {
        let marks = try scopedMarks()
        guard !marks.isEmpty else { throw NoBookmarksError() }
        let groups = context(for: marks)

        let prompt = """
        You are helping someone make sense of the moments they saved while listening to \
        podcasts. Each entry below is one episode, then the moments they bookmarked in it: \
        the time, any tags, their own note, and what was being said at that second.

        \(Self.block(groups, budget: Self.characterBudget))

        Write insights for them, in the language most of their notes and quotes are in:
        - **Themes**: the ideas they keep stopping for, across episodes. Name the episodes.
        - **Connections**: where marks in different episodes speak to each other — agree, \
        disagree, or build on one another. Skip this if there is only one episode.
        - **What their notes say**: what the notes and tags suggest they care about or are \
        working through. Skip this if there are hardly any notes.
        - **Next**: two or three concrete things to listen back to, look into, or reflect on.

        Refer to moments as "Episode title @ m:ss". Be specific and brief — short bullets \
        under each bold heading, no preamble, no closing summary. Markdown, bold headings \
        and "-" bullets only.
        """

        let content = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue,
            maxTokens: Self.maxReplyTokens
        )
        let text = content.trimmed
        guard !text.isEmpty else { throw EmptyReplyError() }
        let result = Saved(text: text, generatedAt: Date(), markCount: marks.count)
        saved = result
        return result
    }

    /// One episode's worth of what the prompt needs, looked up once per episode rather
    /// than per mark.
    struct EpisodeMarks {
        var title: String
        var speaker: String?
        var collection: String?
        var marks: [Bookmark]
    }

    private func context(for marks: [Bookmark]) -> [EpisodeMarks] {
        let trackStore = TrackStore(dbQueue: dbQueue)
        let libraryStore = LibraryStore(dbQueue: dbQueue)
        let tracks = Dictionary(((try? trackStore.all()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let artists = Dictionary(((try? libraryStore.artists()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let albums = Dictionary(((try? libraryStore.albums()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return BookmarkGroup.group(marks) { tracks[$0] }.map { group in
            EpisodeMarks(
                title: group.track.title,
                speaker: group.track.artistID.flatMap { artists[$0] },
                collection: group.track.albumID.flatMap { albums[$0] },
                marks: group.bookmarks
            )
        }
    }

    /// Episodes arrive most-recently-marked first, so filling up to the budget and
    /// stopping keeps the newest and drops the oldest — whole episodes, never half of one.
    static func block(_ episodes: [EpisodeMarks], budget: Int) -> String {
        var out: [String] = []
        var used = 0
        for episode in episodes {
            let entry = describe(episode)
            if used + entry.count > budget, !out.isEmpty { break }
            out.append(entry)
            used += entry.count
        }
        return out.joined(separator: "\n\n")
    }

    static func describe(_ episode: EpisodeMarks) -> String {
        let byline = [episode.speaker, episode.collection].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
        var lines = ["## \(episode.title)" + (byline.isEmpty ? "" : " — \(byline)")]
        for mark in episode.marks {
            var line = "- @\(SeekBar.formatted(mark.position))"
            if !mark.tagList.isEmpty { line += " [\(mark.tagList.joined(separator: ", "))]" }
            if let note = mark.note?.trimmed.nilIfEmpty { line += " note: \(note)" }
            if let said = mark.transcriptText?.trimmed.nilIfEmpty { line += " said: \"\(said)\"" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
