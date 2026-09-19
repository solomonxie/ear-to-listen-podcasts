import Foundation

/// Several vendors (OpenAI itself, Groq, Mistral, DeepSeek, xAI) expose the same
/// `/chat/completions` request/response shape — this is that shared implementation,
/// parameterized by endpoint/model/display name, so each of those vendors is a one-line
/// config rather than its own copy of this. Vendors with their own shape
/// (`AnthropicChatClient`, `GoogleChatClient`) don't come through here.
enum OpenAICompatibleChatClient {
    struct Config {
        var vendorName: String
        var endpoint: URL
        var model: String
    }

    static func runChatCompletion(config: Config, apiKey: String, model: String, messages: [ChatMessage]) async throws -> ChatCompletionResult {
        var request = URLRequest(url: config.endpoint)
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
            throw AiClientError(code: .network, message: "Network request to \(config.vendorName) failed.")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 || status == 403 {
                throw AiClientError(code: .invalidKey, message: "\(config.vendorName) rejected the API key.")
            }
            if status == 429 {
                throw AiClientError(code: .rateLimited, message: "\(config.vendorName) rate-limited this request.")
            }
            throw AiClientError(code: .unknown, message: "\(config.vendorName) request failed (\(status)).")
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String }
                var message: Message
            }
            struct Usage: Decodable {
                var prompt_tokens: Int?
                var completion_tokens: Int?
            }
            var choices: [Choice]
            var model: String?
            var usage: Usage?
        }
        guard
            let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
            let text = chat.choices.first?.message.content
        else {
            throw AiClientError(code: .unknown, message: "Unexpected response shape from \(config.vendorName).")
        }
        // The model the vendor says it used, not the one asked for — they substitute.
        return ChatCompletionResult(
            text: text, model: chat.model ?? model,
            promptTokens: chat.usage?.prompt_tokens, completionTokens: chat.usage?.completion_tokens
        )
    }
}

/// One `Config` per vendor that speaks this shape, rather than a file each — they're the
/// same client, only the endpoint/model differ. Model ids are best-effort defaults
/// (small/cheap tiers); update one if it ever starts 404ing.
extension OpenAICompatibleChatClient.Config {
    static let groq = Self(
        vendorName: "Groq",
        endpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
        model: "llama-3.1-8b-instant"
    )
    static let mistral = Self(
        vendorName: "Mistral",
        endpoint: URL(string: "https://api.mistral.ai/v1/chat/completions")!,
        model: "mistral-small-latest"
    )
    static let deepSeek = Self(
        vendorName: "DeepSeek",
        endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
        model: "deepseek-chat"
    )
    static let xai = Self(
        vendorName: "xAI",
        endpoint: URL(string: "https://api.x.ai/v1/chat/completions")!,
        model: "grok-2-latest"
    )
}
