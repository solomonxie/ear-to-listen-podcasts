import Foundation

/// Most vendors (OpenAI itself, Groq, DeepSeek, Qwen, Kimi, ...) expose the same
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

    static func runChatCompletion(
        config: Config, apiKey: String, model: String, messages: [ChatMessage],
        maxTokens: Int = AiRouter.defaultMaxTokens
    ) async throws -> ChatCompletionResult {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": maxTokens,
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

/// Every vendor that speaks this shape, in one table — they're the same client, only the
/// endpoint differs. Model defaults (small/cheap tiers) live on `AiVendor`. Nil for
/// vendors with their own shape, and for `.custom`, whose endpoint is on the key.
extension OpenAICompatibleChatClient.Config {
    static func forVendor(_ vendor: AiVendor) -> Self? {
        let endpoint: String
        switch vendor {
        case .groq: endpoint = "https://api.groq.com/openai/v1/chat/completions"
        case .mistral: endpoint = "https://api.mistral.ai/v1/chat/completions"
        case .deepSeek: endpoint = "https://api.deepseek.com/chat/completions"
        case .xai: endpoint = "https://api.x.ai/v1/chat/completions"
        case .qwen: endpoint = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .moonshot: endpoint = "https://api.moonshot.cn/v1/chat/completions"
        case .zhipu: endpoint = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .doubao: endpoint = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .openAI, .anthropic, .google, .custom: return nil
        }
        return Self(vendorName: vendor.displayName, endpoint: URL(string: endpoint)!, model: vendor.defaultModel)
    }

    /// A listener's own server. Takes a base (`https://host/v1`) or the full endpoint.
    static func custom(baseURL: String, model: String) -> Self? {
        guard let endpoint = customEndpoint(baseURL), let host = endpoint.host else { return nil }
        return Self(vendorName: host, endpoint: endpoint, model: model)
    }

    static func customEndpoint(_ baseURL: String) -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard
            let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host?.isEmpty == false
        else { return nil }
        return text.hasSuffix("/chat/completions") ? url : url.appendingPathComponent("chat/completions")
    }
}
