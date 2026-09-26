import Foundation
import GRDB

/// Suggests better episode metadata from the episode's own transcript. Requires a
/// *complete* one — a half-transcribed episode hands the model its first ten minutes,
/// which it then confidently names the whole thing after, and a wrong-but-plausible title
/// is worse than the generic tag it replaced. Nothing is applied on its own either:
/// `EpisodeEditView` fills its fields with the suggestion and the listener decides what
/// to save.
struct EpisodeMetadataSuggester {
    struct Suggestion: Decodable {
        var title: String?
        var artist: String?
        var album: String?
        var year: Int?
        var notes: String?

        enum CodingKeys: String, CodingKey { case title, artist, album, year, notes }

        /// Hand-rolled so one odd field (a year sent back as `"2019"`, a null where a
        /// string was asked for) doesn't throw the whole suggestion away.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func string(_ key: CodingKeys) -> String? {
                (try? container.decode(String.self, forKey: key))?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            title = string(.title)
            artist = string(.artist)
            album = string(.album)
            notes = string(.notes)
            year = (try? container.decode(Int.self, forKey: .year)) ?? string(.year).flatMap { Int($0.prefix(4)) }
        }
    }

    struct UnreadableSuggestionError: Error, LocalizedError {
        var errorDescription: String? { "The AI response wasn't in a form the app could read. Try again." }
    }

    /// Why an episode can't be suggested for yet — each case is something the listener can
    /// act on, so `EpisodeEditView` prints it next to the disabled button.
    enum Readiness: Equatable, Sendable {
        case ready
        case noTranscript
        case partial(coverage: Double)
        case unknownDuration

        var isReady: Bool { self == .ready }

        var blockedReason: String? {
            switch self {
            case .ready:
                return nil
            case .noTranscript:
                return "Transcribe this episode first — suggestions read the transcript, not the file name."
            case .partial(let coverage):
                let percent = coverage.formatted(.percent.precision(.fractionLength(0)))
                return "Only \(percent) of this episode is transcribed. Finish it first, or a suggestion just describes the part that got done."
            case .unknownDuration:
                return "This episode's length isn't known yet, so there's no way to tell whether its transcript is complete. Play it once."
            }
        }
    }

    struct NotReadyError: Error, LocalizedError {
        let readiness: Readiness
        var errorDescription: String? { readiness.blockedReason }
    }

    /// How much transcript one suggestion is allowed to send. An hour of speech runs well
    /// past this, so what goes over is sampled across the episode rather than cut off at
    /// the front — the point of waiting for a complete transcript is that the model sees
    /// the whole arc, not a longer version of the opening.
    private static let transcriptCharacterBudget = 24_000
    private static let sampleCount = 12

    var dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue

    /// Whether `suggest` would run, so the button can be disabled with the reason shown
    /// rather than failing after the listener taps it.
    func readiness(track: Track) -> Readiness {
        let segments = (try? TranscriptStore(dbQueue: dbQueue).find(trackID: track.id)) ?? []
        guard !segments.filter({ !$0.text.isEmpty }).isEmpty else { return .noTranscript }
        guard let durationMs = track.durationMs, durationMs > 0 else { return .unknownDuration }
        let duration = Double(durationMs) / 1000
        guard TranscriptCoverage.gaps(in: segments, duration: duration).isEmpty else {
            return .partial(coverage: min(1, TranscriptCoverage.coveredSeconds(segments) / duration))
        }
        return .ready
    }

    func suggest(
        track: Track, title: String, artist: String, album: String, notes: String
    ) async throws -> Suggestion {
        let state = readiness(track: track)
        guard state.isReady else { throw NotReadyError(readiness: state) }
        let excerpt = transcriptExcerpt(trackID: track.id)
        let prompt = """
        You are cleaning up metadata for one podcast episode in a personal library.

        File path: \(track.filePath)
        Current title: \(title.nilIfEmpty ?? "none")
        Current speaker: \(artist.nilIfEmpty ?? "none")
        Current album: \(album.nilIfEmpty ?? "none")
        Current notes: \(notes.nilIfEmpty ?? "none")
        Duration: \(track.durationMs.map { "\($0 / 60000) minutes" } ?? "unknown")
        Transcript\(excerpt.isSampled ? " (whole episode, sampled evenly — \"…\" marks what was left out)" : " (whole episode)"): \(excerpt.text)

        Many files in this library share one generic embedded title, so a title that
        merely repeats a generic tag is worse than one drawn from what's actually said.
        Give a specific title, the speaker/host, the album it belongs to, the
        release year, and notes of at most three sentences. Strict JSON only, no other
        text, null for anything you can't improve on:
        {"title": string|null, "artist": string|null, "album": string|null,
         "year": number|null, "notes": string|null}
        """

        let content = try await AiRouter.runChatCompletion(
            messages: [ChatMessage(role: .user, content: prompt)], dbQueue: dbQueue
        )
        guard let json = Self.jsonObject(in: content),
              let suggestion = try? JSONDecoder().decode(Suggestion.self, from: Data(json.utf8)) else {
            throw UnreadableSuggestionError()
        }
        return suggestion
    }

    private func transcriptExcerpt(trackID: String) -> (text: String, isSampled: Bool) {
        let segments = (try? TranscriptStore(dbQueue: dbQueue).find(trackID: trackID)) ?? []
        let text = segments.map(\.text).joined(separator: " ")
        guard text.count > Self.transcriptCharacterBudget else { return (text, false) }
        return (Self.sampled(text, budget: Self.transcriptCharacterBudget, chunks: Self.sampleCount), true)
    }

    /// Evenly spaced slices covering the beginning, middle and end, rather than a prefix.
    static func sampled(_ text: String, budget: Int, chunks: Int) -> String {
        guard text.count > budget, chunks > 0 else { return text }
        let characters = Array(text)
        let chunkSize = budget / chunks
        let lastStart = characters.count - chunkSize
        let stride = chunks > 1 ? lastStart / (chunks - 1) : 0
        return (0..<chunks)
            .map { index -> String in
                // The final chunk is pinned to the end rather than stepped to, so the
                // close of the episode is always in there — integer striding otherwise
                // stops a little short of it.
                let start = index == chunks - 1 ? lastStart : min(index * stride, lastStart)
                return String(characters[start..<(start + chunkSize)])
            }
            .joined(separator: " … ")
    }

    /// Models like to wrap JSON in prose or a ```json fence even when told not to, so take
    /// the outermost braces rather than trusting the whole reply to parse.
    static func jsonObject(in content: String) -> String? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(content[start...end])
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
