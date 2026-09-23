import Foundation
import GRDB

struct NoAiKeyError: Error, LocalizedError {
    var errorDescription: String? { "No AI key configured. Add one in Settings ▸ AI Features." }
}

/// Dispatches a chat completion across whichever AI keys are configured (`AiKeyStore`),
/// trying each in turn — starting point depending on the chosen strategy — until one
/// succeeds. Sequential is sticky: it keeps starting from the same key call after call,
/// only moving the pointer on once that key itself errors (rate limit, quota, revoked,
/// ...). Round-robin instead advances the starting point by one on every single call,
/// win or lose, to spread load across keys rather than favor one. Either way, a failure
/// falls through to the next configured key before giving up, so one dead key doesn't
/// take AI features down entirely.
enum AiRouter {
    /// What a reply is allowed to be, in tokens, unless the caller says otherwise.
    ///
    /// Every other pass here asks for a handful of fields and answers in a sentence or
    /// two. A summary doesn't: it's a paragraph, eight timed points and a list of terms,
    /// and at this ceiling the JSON stopped mid-object — which arrives as "the response
    /// wasn't in a form the app could read", a parsing error with a spending cause.
    /// Callers that ask for more pass their own.
    static let defaultMaxTokens = 300

    private static let strategyDefaultsKey = "aiKeys.strategy"
    private static let cursorDefaultsKey = "aiKeys.cursor"

    static var strategy: AiKeyStrategy {
        get { AiKeyStrategy(rawValue: UserDefaults.standard.string(forKey: strategyDefaultsKey) ?? "") ?? .sequential }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: strategyDefaultsKey) }
    }

    private static var cursor: Int {
        get { UserDefaults.standard.integer(forKey: cursorDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: cursorDefaultsKey) }
    }

    static func runChatCompletion(
        messages: [ChatMessage], dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue,
        maxTokens: Int = defaultMaxTokens
    ) async throws -> String {
        let store = AiKeyStore(dbQueue: dbQueue)
        let keys = try store.all()
        guard !keys.isEmpty else { throw NoAiKeyError() }

        let currentStrategy = strategy
        let startAt = cursor % keys.count
        let order = Array(keys[startAt...]) + Array(keys[..<startAt])
        if currentStrategy == .roundRobin {
            cursor = (startAt + 1) % keys.count
        }

        let queryStore = AiQueryStore(dbQueue: dbQueue)
        let prompt = transcribe(messages)

        var lastError: Error?
        for (offset, key) in order.enumerated() {
            guard let secret = try? store.secret(forKeyID: key.id), !secret.isEmpty else { continue }
            try? store.bumpRequestCount(id: key.id)
            do {
                let result = try await runChatCompletion(
                    vendor: key.vendor, apiKey: secret, model: key.resolvedModel,
                    messages: messages, maxTokens: maxTokens
                )
                try? queryStore.record(keyID: key.id, vendor: key.vendor, prompt: prompt, result: result)
                return result.text
            } catch {
                // Recorded too: a key that's been refused all week is the thing the
                // history exists to make visible.
                try? queryStore.record(keyID: key.id, vendor: key.vendor, prompt: prompt, error: error)
                lastError = error
                if currentStrategy == .sequential {
                    cursor = (startAt + offset + 1) % keys.count
                }
            }
        }
        throw lastError ?? NoAiKeyError()
    }

    /// The messages as one readable block — what was sent, in the order it was sent, so
    /// the history row can be read back without reconstructing the request.
    private static func transcribe(_ messages: [ChatMessage]) -> String {
        messages.map { "[\($0.role.rawValue)] \($0.content)" }.joined(separator: "\n\n")
    }

    /// Used both by the router above and by "test then save" when adding a key.
    static func runChatCompletion(
        vendor: AiVendor, apiKey: String, model: String? = nil, messages: [ChatMessage],
        maxTokens: Int = defaultMaxTokens
    ) async throws -> ChatCompletionResult {
        let model = model?.nilIfEmpty ?? vendor.defaultModel
        switch vendor {
        case .openAI:
            return try await OpenAIChatClient.runChatCompletion(apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .anthropic:
            return try await AnthropicChatClient.runChatCompletion(apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .google:
            return try await GoogleChatClient.runChatCompletion(apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .groq:
            return try await OpenAICompatibleChatClient.runChatCompletion(config: .groq, apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .mistral:
            return try await OpenAICompatibleChatClient.runChatCompletion(config: .mistral, apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .deepSeek:
            return try await OpenAICompatibleChatClient.runChatCompletion(config: .deepSeek, apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        case .xai:
            return try await OpenAICompatibleChatClient.runChatCompletion(config: .xai, apiKey: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        }
    }
}
