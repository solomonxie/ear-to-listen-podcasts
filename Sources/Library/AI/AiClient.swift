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

enum AiClientErrorCode {
    case invalidKey, rateLimited, network, unknown
}

struct AiClientError: Error, LocalizedError {
    var code: AiClientErrorCode
    var message: String
    var errorDescription: String? { message }
}
