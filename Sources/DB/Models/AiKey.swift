import Foundation
import GRDB

enum AiVendor: String, Codable, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case google = "google"
    case groq = "groq"
    case mistral = "mistral"
    case deepSeek = "deepseek"
    case xai = "xai"
    case qwen = "qwen"
    case moonshot = "moonshot"
    case zhipu = "zhipu"
    case doubao = "doubao"
    /// Any OpenAI-compatible `/chat/completions` server; the key row carries its URL.
    case custom = "custom"

    /// Licensed in mainland China, so offered on the China storefront.
    var isChinaApproved: Bool {
        switch self {
        case .deepSeek, .qwen, .moonshot, .zhipu, .doubao, .custom: return true
        case .openAI, .anthropic, .google, .groq, .mistral, .xai: return false
        }
    }

    func isOffered(inChina china: Bool) -> Bool { !china || isChinaApproved }

    var isOffered: Bool { isOffered(inChina: AppStorefront.isChina) }

    static var offered: [AiVendor] { allCases.filter(\.isOffered) }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google Gemini"
        case .groq: return "Groq"
        case .mistral: return "Mistral"
        case .deepSeek: return "DeepSeek"
        case .xai: return "xAI (Grok)"
        case .qwen: return "Qwen (Alibaba)"
        case .moonshot: return "Kimi (Moonshot)"
        case .zhipu: return "GLM (Zhipu)"
        case .doubao: return "Doubao (Volcengine)"
        case .custom: return String(localized: "Custom (OpenAI-compatible)")
        }
    }

    /// What this vendor's key looks like — doubles as the add-key field's placeholder.
    var keyHint: String {
        switch self {
        case .openAI, .deepSeek, .qwen, .moonshot: return "sk-…"
        case .anthropic: return "sk-ant-…"
        case .google: return "AIza…"
        case .groq: return "gsk_…"
        case .xai: return "xai-…"
        case .mistral, .zhipu, .doubao, .custom: return "…"
        }
    }

    /// What this vendor is called when no model has been picked. The cheap, fast tier in
    /// each family: this runs per-episode during a sync, so the default has to be one
    /// nobody minds spending. Empty for `.custom`, which has no default to fall back on.
    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .google: return "gemini-1.5-flash"
        case .groq: return "llama-3.1-8b-instant"
        case .mistral: return "mistral-small-latest"
        case .deepSeek: return "deepseek-v4-pro"
        case .xai: return "grok-2-latest"
        case .qwen: return "qwen-plus"
        case .moonshot: return "moonshot-v1-8k"
        case .zhipu: return "glm-4-flash"
        case .doubao: return "doubao-1-5-lite-32k-250115"
        case .custom: return ""
        }
    }

    /// The ones worth offering without typing. Not exhaustive and not validated — vendors
    /// add and retire models faster than an app ships, which is exactly why "Custom…"
    /// exists beside this list rather than instead of it.
    var presetModels: [String] {
        switch self {
        case .openAI: return ["gpt-4o-mini", "gpt-4o", "o4-mini"]
        case .anthropic:
            return ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5"]
        case .google: return ["gemini-1.5-flash", "gemini-1.5-pro", "gemini-2.0-flash"]
        case .groq: return ["llama-3.1-8b-instant", "llama-3.3-70b-versatile"]
        case .mistral: return ["mistral-small-latest", "mistral-large-latest"]
        case .deepSeek: return ["deepseek-v4-pro"]
        case .xai: return ["grok-2-latest", "grok-3"]
        case .qwen: return ["qwen-turbo", "qwen-plus", "qwen-max"]
        case .moonshot: return ["moonshot-v1-8k", "moonshot-v1-32k", "kimi-latest"]
        case .zhipu: return ["glm-4-flash", "glm-4-air", "glm-4-plus"]
        case .doubao: return ["doubao-1-5-lite-32k-250115", "doubao-1-5-pro-32k-250115"]
        case .custom: return []
        }
    }

    /// Where to go make one, linked from the add-key screen so adding a key doesn't
    /// require already knowing each vendor's console. Nil for `.custom`.
    var docsURL: URL? {
        switch self {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .google: return URL(string: "https://aistudio.google.com/apikey")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .xai: return URL(string: "https://console.x.ai")
        case .qwen: return URL(string: "https://bailian.console.aliyun.com/?apiKey=1")
        case .moonshot: return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .zhipu: return URL(string: "https://open.bigmodel.cn/usercenter/apikeys")
        case .doubao: return URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")
        case .custom: return nil
        }
    }
}

enum AiKeyStrategy: String, Codable, CaseIterable {
    case sequential
    case roundRobin

    var displayName: String {
        switch self {
        case .sequential: return "Sequential"
        case .roundRobin: return "Round-robin"
        }
    }
}

/// One configured AI key — the secret itself lives in `CredentialStore` (Keychain),
/// keyed by `AiKeyStore.secretKey(id:)`; this row is just the non-secret metadata
/// (which vendor, how much it's been used, its place in the fallback order).
struct AiKey: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "aiKeys"

    var id: String
    var vendor: AiVendor
    /// Nil means this vendor's `defaultModel` — see the `v24_ai_key_model` migration.
    var model: String?
    var requestCount: Int = 0
    var position: Int
    var createdAt: Date
    /// Only for `.custom`: the server's base URL, as typed.
    var baseURL: String?

    /// What this key will actually call.
    var resolvedModel: String { model?.nilIfEmpty ?? vendor.defaultModel }

    /// A custom key reads as its host, so two of them can be told apart.
    var displayName: String {
        guard vendor == .custom, let host = baseURL.flatMap({ URL(string: $0)?.host }) else {
            return vendor.displayName
        }
        return host
    }
}
