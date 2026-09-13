import Foundation

/// Best-effort title/artist/album guesses from OpenAI, using only a file's path/name
/// and whatever tags were already embedded in it — never the audio content itself
/// (too heavy to send/transcribe during a routine sync). Skipped entirely when no
/// key is set in Settings ▸ AI Features.
struct ContentAnalyzer {
    private let credentials = CredentialStore()

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let model = "gpt-4o-mini"

    struct Guess: Decodable {
        var title: String?
        var artist: String?
        var album: String?
    }

    /// Returns `nil` on any failure (missing key, network error, bad response) — this is
    /// purely an enhancement over the embedded metadata, sync must not fail without it.
    func analyze(filePath: String, title: String?, artist: String?, album: String?) async -> Guess? {
        guard
            let apiKey = try? credentials.get(SettingsViewModel.openAIAPIKeyKey),
            !apiKey.isEmpty
        else {
            return nil
        }

        let prompt = """
        An audio file has this path: \(filePath)
        Its embedded metadata (may be missing or generic): title=\(title ?? "none"), artist=\(artist ?? "none"), album=\(album ?? "none")

        From the path and filename alone, guess better values for title, artist (host/show
        name), and album (show/series name). Respond with strict JSON only:
        {"title": string|null, "artist": string|null, "album": string|null}
        Use null for any field you can't confidently improve on the embedded metadata.
        """

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": prompt]],
        ])

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else {
            return nil
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String }
                var message: Message
            }
            var choices: [Choice]
        }

        guard
            let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let content = chat.choices.first?.message.content,
            let guessData = content.data(using: .utf8),
            let guess = try? JSONDecoder().decode(Guess.self, from: guessData)
        else {
            return nil
        }
        return guess
    }
}
