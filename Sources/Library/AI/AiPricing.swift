import Foundation

/// Published list prices per million tokens, for showing roughly what a call cost.
///
/// An estimate and labelled as one everywhere it's shown: vendors change prices, bill in
/// their own rounding, and discount things this can't see (cached input, batch tiers).
/// A model nobody here has a price for returns nil rather than a confident zero.
enum AiPricing {
    /// (input, output) USD per 1M tokens.
    private static let perMillionUSD: [String: (input: Double, output: Double)] = [
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4o": (2.50, 10.00),
        "claude-haiku-4-5": (1.00, 5.00),
        "claude-sonnet-5": (2.00, 10.00),
        "claude-opus-5": (5.00, 25.00),
        "gemini-1.5-flash": (0.075, 0.30),
        "gemini-2.0-flash": (0.10, 0.40),
        "llama-3.1-8b-instant": (0.05, 0.08),
        "mistral-small-latest": (0.20, 0.60),
        "deepseek-chat": (0.27, 1.10),
        "grok-2-latest": (2.00, 10.00),
    ]

    /// USD per picture, for the models billed by the image rather than by the token.
    /// One 1024×1024 at the quality the app asks for, which is each vendor's default.
    private static let perImageUSD: [String: Double] = [
        "gpt-image-1": 0.042,
        "grok-2-image": 0.07,
    ]

    /// Nil for anything that isn't one of the image models, so a chat row can fall
    /// through to this without inventing a per-picture price for a chat model.
    static func imageEstimate(model: String, images: Int = 1) -> Double? {
        perImageUSD[model].map { $0 * Double(images) }
    }

    static func estimate(model: String, promptTokens: Int?, completionTokens: Int?) -> Double? {
        guard promptTokens != nil || completionTokens != nil, let price = price(for: model) else { return nil }
        return Double(promptTokens ?? 0) / 1_000_000 * price.input
            + Double(completionTokens ?? 0) / 1_000_000 * price.output
    }

    /// Vendors answer with dated ids (`claude-haiku-4-5-20251001`, `gpt-4o-mini-2024-07-18`)
    /// for models priced under the undated name, so the longest matching prefix wins.
    private static func price(for model: String) -> (input: Double, output: Double)? {
        if let exact = perMillionUSD[model] { return exact }
        return perMillionUSD
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
