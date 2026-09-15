import Foundation

/// Hand-rolled `fetch`/URLSession call, no SDK — one endpoint isn't worth a dependency.
enum OpenAIChatClient {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Cheap and fast enough for guessing episode metadata from a file path — not a
    /// hard requirement, just a reasonable default.
    private static let model = "gpt-4o-mini"

    static func runChatCompletion(apiKey: String, messages: [ChatMessage]) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 300,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AiClientError(code: .network, message: "Network request to OpenAI failed.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { throw AiClientError(code: .invalidKey, message: "OpenAI rejected the API key.") }
            if status == 429 { throw AiClientError(code: .rateLimited, message: "OpenAI rate-limited this request.") }
            throw AiClientError(code: .unknown, message: "OpenAI request failed (\(status)).")
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
            let text = chat.choices.first?.message.content
        else {
            throw AiClientError(code: .unknown, message: "Unexpected response shape from OpenAI.")
        }
        return text
    }
}
