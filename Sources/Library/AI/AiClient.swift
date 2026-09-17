import Foundation

/// Shared across every vendor client (OpenAIChatClient, AnthropicChatClient, ...) so
/// none of them import from one another.
struct ChatMessage {
    enum Role: String {
        case system, user
    }
    var role: Role
    var content: String
}

/// What came back from one call. The token counts and model are what make an entry in
/// the key's history worth reading — "what did this cost me" can't be answered without
/// them, and only the vendor knows the real numbers.
struct ChatCompletionResult {
    var text: String
    var model: String
    var promptTokens: Int?
    var completionTokens: Int?
}

enum AiClientErrorCode {
    case invalidKey, rateLimited, network, unknown
}

struct AiClientError: Error, LocalizedError {
    var code: AiClientErrorCode
    var message: String
    var errorDescription: String? { message }
}
