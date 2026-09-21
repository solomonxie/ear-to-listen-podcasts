import Foundation
import GRDB

/// One call made with one key: what was asked, what came back, what it cost.
///
/// Kept because a key's only other visible fact is a request count, which answers
/// nothing — not why the bill moved, not which feature is spending, not whether a
/// failing key is failing on every call or just one. Prompt and response are stored
/// trimmed (`maxStoredCharacters`): a transcript-sized prompt is worth recognising, not
/// worth keeping a second copy of.
struct AiQuery: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "aiQueries"
    static let maxStoredCharacters = 4000

    var id: String
    var keyID: String
    var vendor: AiVendor
    var model: String
    var prompt: String
    var response: String?
    /// Set instead of `response` when the vendor refused or the network did — a failed
    /// call is the one you most want to see afterwards.
    var errorMessage: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var createdAt: Date

    var totalTokens: Int? {
        guard promptTokens != nil || completionTokens != nil else { return nil }
        return (promptTokens ?? 0) + (completionTokens ?? 0)
    }

    /// Falling back to the per-picture price covers the image models, which report no
    /// tokens at all. One row is one picture — the app only ever asks for one.
    var estimatedCostUSD: Double? {
        AiPricing.estimate(model: model, promptTokens: promptTokens, completionTokens: completionTokens)
            ?? AiPricing.imageEstimate(model: model)
    }

    static func trimmed(_ text: String) -> String {
        guard text.count > maxStoredCharacters else { return text }
        return text.prefix(maxStoredCharacters) + "\n…(trimmed)"
    }
}
