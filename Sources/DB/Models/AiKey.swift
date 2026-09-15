import Foundation
import GRDB

enum AiVendor: String, Codable, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
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
    var requestCount: Int = 0
    var position: Int
    var createdAt: Date
}
