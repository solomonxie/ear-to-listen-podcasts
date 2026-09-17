import Foundation
import GRDB

/// One batch pass over a whole album. Every episode that already has a complete transcript
/// stored locally goes into a single request, and the answer carries a title (and notes)
/// per episode plus a name/speaker/notes for the album itself — so a collection of
/// identically-tagged files can be sorted out in one go.
///
/// Nothing is downloaded and nothing is transcribed to make this work: episodes without a
/// finished transcript are reported as skipped rather than guessed at, on the same
/// reasoning as `EpisodeMetadataSuggester` refusing a partial one.
struct AlbumMetadataSuggester {
    struct EpisodeSuggestion: Decodable, Identifiable {
        var index: Int
        var title: String?
        var notes: String?
        var year: Int?

        var id: Int { index }

        enum CodingKeys: String, CodingKey { case index, title, notes, year }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = (try? container.decode(Int.self, forKey: .index)) ?? -1
            title = Self.string(container, .title)
            notes = Self.string(container, .notes)
            year = (try? container.decode(Int.self, forKey: .year)) ?? Self.string(container, .year).flatMap { Int($0.prefix(4)) }
        }

        private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
            (try? container.decode(String.self, forKey: key))?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    struct AlbumSuggestion: Decodable {
        var name: String?
        var artist: String?
        var notes: String?
    }

    struct Result: Decodable {
        var album: AlbumSuggestion?
        var episodes: [EpisodeSuggestion]

        enum CodingKeys: String, CodingKey { case album, episodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            album = try? container.decode(AlbumSuggestion.self, forKey: .album)
            episodes = ((try? container.decode([EpisodeSuggestion].self, forKey: .episodes)) ?? []).filter { $0.index >= 0 }
        }
    }

    struct NothingToAnalyzeError: Error, LocalizedError {
        var errorDescription: String? {
            "No episode in this album has a finished transcript yet. Transcribe some first — this only reads what's already on the phone."
        }
    }

    /// Shared across every episode in the request, so a 40-episode album doesn't send 40
    /// times as much as a 1-episode one.
    static let totalCharacterBudget = 24_000
    private static let minimumPerEpisode = 600
    private static let sampleChunks = 6

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    /// Splits an album's episodes into the ones this can read and the ones it can't, so
    /// the screen can say what it's about to skip before anything is spent.
    func partition(tracks: [Track]) -> (ready: [Track], skipped: [Track]) {
        let suggester = EpisodeMetadataSuggester(dbQueue: dbQueue)
        var ready: [Track] = []
        var skipped: [Track] = []
        for track in tracks {
            suggester.readiness(track: track).isReady ? ready.append(track) : skipped.append(track)
        }
        return (ready, skipped)
    }

    func analyze(album: Album, artistName: String?, tracks: [Track]) async throws -> Result {
        let ready = partition(tracks: tracks).ready
        guard !ready.isEmpty else { throw NothingToAnalyzeError() }

        let budgetEach = max(Self.minimumPerEpisode, Self.totalCharacterBudget / ready.count)
        let digests = ready.enumerated().map { index, track in
            """
            [\(index)] file: \(track.filePath)
            current title: \(track.title)
            length: \(track.durationMs.map { "\($0 / 60000) min" } ?? "unknown")
            transcript: \(transcript(for: track, budget: budgetEach))
            """
        }

        let prompt = """
        You are sorting out one album in a personal podcast library. Every episode below is
        fully transcribed; the transcripts are sampled evenly across each episode, with "…"
        marking what was left out.

        Album: \(album.name)
        Speaker: \(artistName?.nilIfEmpty ?? "none")
        Album notes: \(album.notes?.nilIfEmpty ?? "none")

        \(digests.joined(separator: "\n\n"))

        These files often share one generic embedded title, so titles that merely repeat
        the album name are the thing to replace. Give each episode a specific title drawn
        from what's actually said, keep the set consistent in style, and don't invent a
        numbering the transcripts don't support. Episode notes: at most two sentences.
        Album notes: at most three. Keep every index exactly as given. Strict JSON only, no
        other text, null for anything you can't improve on:
        {"album": {"name": string|null, "artist": string|null, "notes": string|null},
         "episodes": [{"index": number, "title": string|null, "notes": string|null, "year": number|null}]}
        """

        let content = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue
        )
        guard let json = EpisodeMetadataSuggester.jsonObject(in: content),
              let result = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)) else {
            throw EpisodeMetadataSuggester.UnreadableSuggestionError()
        }
        return result
    }

    private func transcript(for track: Track, budget: Int) -> String {
        let segments = (try? TranscriptStore(dbQueue: dbQueue).find(trackID: track.id)) ?? []
        let text = segments.map(\.text).joined(separator: " ")
        return EpisodeMetadataSuggester.sampled(text, budget: budget, chunks: Self.sampleChunks)
    }
}
