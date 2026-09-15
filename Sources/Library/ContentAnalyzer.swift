import Foundation

/// Best-effort title/artist/album guesses from AI, using only a file's path/name and
/// whatever tags were already embedded in it — never the audio content itself (too
/// heavy to send/transcribe during a routine sync). Skipped entirely when no AI key is
/// configured in Settings ▸ AI Features, or when embedded metadata is already complete.
/// Routes through `AiRouter`, so it works with whichever vendor(s) are configured.
struct ContentAnalyzer {
    struct Guess: Decodable {
        var title: String?
        var artist: String?
        var album: String?
    }

    /// Returns `nil` on any failure (no key configured, network error, bad response), or
    /// when `title`/`artist`/`album` are all already filled in — this is purely an
    /// enhancement over embedded metadata, sync must not fail without it and shouldn't
    /// pay for it when there's nothing to improve.
    func analyze(filePath: String, title: String?, artist: String?, album: String?) async -> Guess? {
        guard [title, artist, album].contains(where: { $0?.isEmpty != false }) else {
            return nil
        }

        let prompt = """
        Path: \(filePath)
        Known: title=\(title ?? "none"), artist=\(artist ?? "none"), album=\(album ?? "none")
        Guess better title/artist(host)/album(show) from the path alone. Strict JSON only,
        no other text:
        {"title": string|null, "artist": string|null, "album": string|null}
        null = can't improve.
        """

        guard
            let content = try? await AiRouter.runChatCompletion(messages: [ChatMessage(role: .user, content: prompt)]),
            let guessData = content.data(using: .utf8),
            let guess = try? JSONDecoder().decode(Guess.self, from: guessData)
        else {
            return nil
        }
        return guess
    }
}
