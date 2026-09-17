import Foundation

/// Hand-rolled URLSession call, no SDK — one endpoint isn't worth a dependency. The
/// request/response handling itself lives in `OpenAICompatibleChatClient`, shared with
/// the other vendors that speak the same `/chat/completions` shape.
enum OpenAIChatClient {
    /// Cheap and fast enough for guessing episode metadata from a file path — not a
    /// hard requirement, just a reasonable default.
    private static let config = OpenAICompatibleChatClient.Config(
        vendorName: "OpenAI",
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-4o-mini"
    )

    static func runChatCompletion(apiKey: String, messages: [ChatMessage]) async throws -> ChatCompletionResult {
        try await OpenAICompatibleChatClient.runChatCompletion(config: config, apiKey: apiKey, messages: messages)
    }
}
