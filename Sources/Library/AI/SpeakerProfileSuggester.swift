import Foundation
import GRDB

/// Builds a rounded profile of a speaker out of what the library already knows about
/// them — their name, the shows and collections they appear on, and the titles of their
/// episodes. Nothing is downloaded, nothing is transcribed, and no audio is read: this is
/// the metadata on the speaker's own page, handed to the model along with whatever it
/// knows about a person by that name.
///
/// That last part is also the risk, so the prompt is explicit about it — a name the model
/// doesn't recognise should come back null rather than as a confident invention.
struct SpeakerProfileSuggester {
    struct Suggestion: Decodable {
        var bio: String?
        var knownFor: String?
        var background: String?
        var profile: String?
        var link: String?

        var isEmpty: Bool {
            bio == nil && knownFor == nil && background == nil && profile == nil && link == nil
        }

        enum CodingKeys: String, CodingKey { case bio, knownFor, background, profile, link }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                (try? container.decode(String.self, forKey: key))?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            bio = text(.bio)
            knownFor = text(.knownFor)
            background = text(.background)
            profile = text(.profile)
            // A fabricated URL is worse than none — it looks like a citation. Anything
            // that isn't a plain http(s) address is dropped rather than shown.
            link = text(.link).flatMap { candidate in
                guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host != nil else { return nil }
                return candidate
            }
        }
    }

    struct NothingKnownError: Error, LocalizedError {
        var errorDescription: String? {
            "There's nothing to go on yet — this speaker has no episodes in your library."
        }
    }

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    func analyze(speaker: Artist, albums: [Album], tracks: [Track]) async throws -> Suggestion {
        guard !tracks.isEmpty || !albums.isEmpty else { throw NothingKnownError() }

        // Collections, not episode titles. A prolific speaker has thousands of episodes
        // and their titles are mostly the same few words with a number after them —
        // paying to send 1,469 of those bought nothing the album names didn't already
        // say, and made a request big enough that the answer came back unparseable.
        let countByAlbum = Dictionary(grouping: tracks, by: { $0.albumID })
            .reduce(into: [String: Int]()) { result, entry in
                if let id = entry.key { result[id] = entry.value.count }
            }
        let lines = albums.map { album in
            let year = album.year.map { " · \($0)" } ?? ""
            let count = countByAlbum[album.id].map { " · \($0) episodes" } ?? ""
            let notes = album.notes?.nilIfEmpty.map { " — \($0)" } ?? ""
            return "- \(album.name)\(year)\(count)\(notes)"
        }
        let years = Set(tracks.compactMap(\.year)).sorted()

        let prompt = """
        You are filling in the profile page for one speaker in someone's personal podcast
        library. Everything below is collection-level metadata. You have not heard the
        episodes and no transcript is included.

        Name: \(speaker.name)
        Current bio: \(speaker.bio?.nilIfEmpty ?? "none")
        Current known for: \(speaker.knownFor?.nilIfEmpty ?? "none")
        Current background: \(speaker.background?.nilIfEmpty ?? "none")
        Spoken language: \(speaker.language?.nilIfEmpty ?? "not set")
        Episodes in the library: \(tracks.count)
        Years covered: \(years.isEmpty ? "unknown" : "\(years.first!)–\(years.last!)")
        Collections (\(albums.count)):
        \(lines.isEmpty ? "- none" : lines.joined(separator: "\n"))

        Two sources, and keep them straight. The collection names are evidence — they show
        what this speaker covers here. Anything about the person themselves comes from what
        you already know about someone of this name, which may be nothing: if you can't
        place them with reasonable confidence, return null for `background` rather than
        guessing a career, and build `profile` from the collections alone. Never invent an
        employer, a credential, or a date. Say "appears to" where the names imply rather
        than state something.

        Write in the same language the collection names are in.

        - bio: one line, what they're known for. At most 15 words.
        - knownFor: the recurring themes, comma-separated. At most 6 of them, no sentence.
        - background: who they are away from the microphone — role, affiliation, what came
          before. Two sentences at most. Null if you don't know the person.
        - profile: the long read, 2-4 short paragraphs, tying together who they are and
          what this particular library of their work covers. Plain text, no markdown.
        - link: one public page about this person — Wikipedia for preference, else a
          university or organisation profile, else their own site. **Only if you are
          confident the page exists and is about this person.** A plausible-looking URL you
          have not actually seen is worse than null, because it reads as a citation. Null
          whenever `background` is null: if you can't place them, you don't have their page
          either.

        Strict JSON only, no other text, null for anything you can't improve on:
        {"bio": string|null, "knownFor": string|null, "background": string|null,
         "profile": string|null, "link": string|null}
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
}
