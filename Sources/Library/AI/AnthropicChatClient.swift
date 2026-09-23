import Foundation

/// Second vendor for AI keys' multi-provider support — same hand-rolled URLSession
/// choice as `OpenAIChatClient`. Anthropic's Messages API takes system prompts as a
/// separate top-level field, not a message role, so those get pulled out of
/// `messages` before sending.
enum AnthropicChatClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    static func runChatCompletion(
        apiKey: String, model: String, messages: [ChatMessage],
        maxTokens: Int = AiRouter.defaultMaxTokens
    ) async throws -> ChatCompletionResult {
        let system = messages
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n\n")
        let userMessages = messages
            .filter { $0.role != .system }
            .map { ["role": "user", "content": $0.content] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": userMessages]
        if !system.isEmpty { body["system"] = system }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AiClientError(code: .network, message: "Network request to Anthropic failed.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { throw AiClientError(code: .invalidKey, message: "Anthropic rejected the API key.") }
            if status == 429 { throw AiClientError(code: .rateLimited, message: "Anthropic rate-limited this request.") }
            throw AiClientError(code: .unknown, message: "Anthropic request failed (\(status)).")
        }

        struct MessagesResponse: Decodable {
            struct Block: Decodable { var text: String? }
            struct Usage: Decodable {
                var input_tokens: Int?
                var output_tokens: Int?
            }
            var content: [Block]
            var model: String?
            var usage: Usage?
        }
        guard
            let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data),
            let text = decoded.content.first?.text
        else {
            throw AiClientError(code: .unknown, message: "Unexpected response shape from Anthropic.")
        }
        return ChatCompletionResult(
            text: text, model: decoded.model ?? model,
            promptTokens: decoded.usage?.input_tokens, completionTokens: decoded.usage?.output_tokens
        )
    }
}
