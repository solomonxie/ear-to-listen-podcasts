import Foundation
import GRDB

/// Describes a collection from what the library already knows about it — its name, its
/// speaker, and the titles of the episodes in it. No audio is read and no transcript is
/// included, which is what makes this work on a collection nothing has been transcribed
/// from yet.
///
/// Distinct from `AlbumMetadataSuggester`, which reads finished transcripts to rewrite
/// each episode's *title*. This one leaves the episodes alone and answers "what is this
/// collection?" instead.
struct AlbumProfileSuggester {
    struct Suggestion: Decodable {
        var notes: String?
        var profile: String?
        var year: Int?
        /// Subject tags for the collection. Topics hang off albums now, and nothing else
        /// in the app populates them — so if this pass doesn't suggest any, the shelf
        /// stays empty forever.
        var topics: [String] = []

        var isEmpty: Bool { notes == nil && profile == nil && year == nil && topics.isEmpty }

        enum CodingKeys: String, CodingKey { case notes, profile, year, topics }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                (try? container.decode(String.self, forKey: key))?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            notes = text(.notes)
            profile = text(.profile)
            year = (try? container.decode(Int.self, forKey: .year)) ?? text(.year).flatMap { Int($0.prefix(4)) }
            topics = ((try? container.decode([String].self, forKey: .topics)) ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    struct NothingKnownError: Error, LocalizedError {
        var errorDescription: String? {
            "There's nothing to go on yet — this collection has no episodes in it."
        }
    }

    static let titleLimit = 150

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    func analyze(album: Album, artistName: String?, tracks: [Track]) async throws -> Suggestion {
        guard !tracks.isEmpty else { throw NothingKnownError() }

        let titles = tracks.prefix(Self.titleLimit).map { track in
            let year = track.year.map { " (\($0))" } ?? ""
            let length = track.durationMs.map { " · \($0 / 60000) min" } ?? ""
            return "- \(track.title)\(year)\(length)"
        }
        let more = tracks.count > Self.titleLimit ? "\n…and \(tracks.count - Self.titleLimit) more." : ""
        let years = Set(tracks.compactMap(\.year)).sorted()
        let folder = commonFolder(tracks)

        let prompt = """
        You are describing one collection in someone's personal podcast library. Everything
        below is file and collection metadata. You have not heard the episodes and no
        transcript is included.

        Collection: \(album.name)
        Speaker: \(artistName?.nilIfEmpty ?? "none")
        Collection year: \(album.year.map(String.init) ?? "not set")
        Years on the episodes: \(years.isEmpty ? "none" : years.map(String.init).joined(separator: ", "))
        Current notes: \(album.notes?.nilIfEmpty ?? "none")
        Folder: \(folder ?? "episodes are spread across folders")
        Episodes (\(tracks.count) total):
        \(titles.joined(separator: "\n"))\(more)

        The titles are your evidence for what this collection covers; anything about the
        speaker or a named series comes from what you already know, which may be nothing.
        Don't invent a broadcaster, a season structure, or a date the metadata doesn't
        support. If the titles are generic and you can't place the series, say what can be
        said from the little there is and leave the rest null — a short honest answer beats
        a confident wrong one.

        Write in the same language the episode titles are in.

        - notes: what this collection is, at most three sentences. This is the line that
          sits under the title on its page.
        - profile: the long read, 2-4 short paragraphs — what it covers, how it's put
          together, who it's for. Plain text, no markdown headings.
        - year: the year the collection is from, only if the titles or episode years make
          it clear. Null otherwise.
        - topics: 1-5 short subject tags for the whole collection — the words someone would
          browse by, like "history" or "meditation". One or two words each, no sentences.
          Empty array if the titles don't support any.

        Strict JSON only, no other text, null for anything you can't improve on:
        {"notes": string|null, "profile": string|null, "year": number|null, "topics": [string]}
        """

        let content = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue
        )
        guard let json = EpisodeMetadataSuggester.jsonObject(in: content),
              let suggestion = try? JSONDecoder().decode(Suggestion.self, from: Data(json.utf8)) else {
            throw EpisodeMetadataSuggester.UnreadableSuggestionError()
        }
        return suggestion
    }

    /// The deepest folder every episode shares, when there is one — it's often the
    /// clearest hint at what a badly-tagged collection actually is.
    private func commonFolder(_ tracks: [Track]) -> String? {
        let folders = tracks.map { ($0.filePath as NSString).deletingLastPathComponent }
        guard let first = folders.first, !first.isEmpty, folders.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
