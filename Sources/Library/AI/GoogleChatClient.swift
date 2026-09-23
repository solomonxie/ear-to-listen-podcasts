import Foundation

/// Gemini's own request/response shape — system prompts go in a separate top-level field
/// (like Anthropic's), and the key rides as a query parameter rather than a header, so
/// this can't share `OpenAICompatibleChatClient`.
enum GoogleChatClient {

    static func runChatCompletion(
        apiKey: String, model: String, messages: [ChatMessage],
        maxTokens: Int = AiRouter.defaultMaxTokens
    ) async throws -> ChatCompletionResult {
        let systemInstruction = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let contents = messages
            .filter { $0.role != .system }
            .map { ["role": "user", "parts": [["text": $0.content]]] }

        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        ) else {
            throw AiClientError(code: .invalidKey, message: "That doesn't look like a usable Google API key.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": ["maxOutputTokens": maxTokens],
        ]
        if !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AiClientError(code: .network, message: "Network request to Google failed.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Gemini answers a bad key with 400, not 401.
            if status == 400 || status == 403 {
                throw AiClientError(code: .invalidKey, message: "Google rejected the API key.")
            }
            if status == 429 {
                throw AiClientError(code: .rateLimited, message: "Google rate-limited this request.")
            }
            throw AiClientError(code: .unknown, message: "Google request failed (\(status)).")
        }

        struct GenerateContentResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { var text: String? }
                    var parts: [Part]
                }
                var content: Content
            }
            struct UsageMetadata: Decodable {
                var promptTokenCount: Int?
                var candidatesTokenCount: Int?
            }
            var candidates: [Candidate]
            var usageMetadata: UsageMetadata?
        }
        guard
            let decoded = try? JSONDecoder().decode(GenerateContentResponse.self, from: data),
            let text = decoded.candidates.first?.content.parts.first?.text
        else {
            throw AiClientError(code: .unknown, message: "Unexpected response shape from Google.")
        }
        return ChatCompletionResult(
            text: text, model: model,
            promptTokens: decoded.usageMetadata?.promptTokenCount,
            completionTokens: decoded.usageMetadata?.candidatesTokenCount
        )
    }
}
