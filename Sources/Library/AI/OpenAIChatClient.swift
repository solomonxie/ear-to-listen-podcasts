import Foundation

/// Hand-rolled URLSession call, no SDK — one endpoint isn't worth a dependency. The
/// request/response handling itself lives in `OpenAICompatibleChatClient`, shared with
/// the other vendors that speak the same `/chat/completions` shape.
enum OpenAIChatClient {
    private static let config = OpenAICompatibleChatClient.Config(
        vendorName: "OpenAI",
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: AiVendor.openAI.defaultModel
    )

    static func runChatCompletion(
        apiKey: String, model: String, messages: [ChatMessage],
        maxTokens: Int = AiRouter.defaultMaxTokens
    ) async throws -> ChatCompletionResult {
        try await OpenAICompatibleChatClient.runChatCompletion(
            config: config, apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens
        )
    }
}
