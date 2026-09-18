import GRDB
import XCTest
@testable import EarToListen

final class AiQueryHistoryTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    /// Vendors answer with a dated id for a model priced under its undated name, so a
    /// literal lookup would show "—" for every real call.
    func testPricingMatchesTheDatedModelIdsVendorsActuallyReturn() {
        let dated = AiPricing.estimate(model: "claude-haiku-4-5-20251001", promptTokens: 1_000_000, completionTokens: 0)
        XCTAssertEqual(try XCTUnwrap(dated), 1.00, accuracy: 0.0001)

        let output = AiPricing.estimate(model: "gpt-4o-mini-2024-07-18", promptTokens: 0, completionTokens: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(output), 0.60, accuracy: 0.0001)

        XCTAssertNil(AiPricing.estimate(model: "some-model-nobody-priced", promptTokens: 100, completionTokens: 100))
        // No counts, no guess — a zero would read as "this was free".
        XCTAssertNil(AiPricing.estimate(model: "gpt-4o-mini", promptTokens: nil, completionTokens: nil))
    }

    func testAFailedCallIsKeptWithItsReasonRatherThanDropped() throws {
        let dbQueue = try makeDatabase()
        let store = AiQueryStore(dbQueue: dbQueue)
        try store.record(
            keyID: "k1", vendor: .openAI, prompt: "Guess this title",
            error: AiClientError(code: .rateLimited, message: "OpenAI rate-limited this request.")
        )

        let recorded = try XCTUnwrap(store.recent(keyID: "k1").first)
        XCTAssertEqual(recorded.errorMessage, "OpenAI rate-limited this request.")
        XCTAssertNil(recorded.response)
        XCTAssertNil(recorded.estimatedCostUSD)
    }

    /// History is capped per key, so one busy key can't push a rarely used key's calls out.
    func testHistoryIsTrimmedPerKey() throws {
        let dbQueue = try makeDatabase()
        let store = AiQueryStore(dbQueue: dbQueue)
        try store.record(keyID: "quiet", vendor: .anthropic, prompt: "only call",
                         result: ChatCompletionResult(text: "ok", model: "claude-haiku-4-5", promptTokens: 10, completionTokens: 2))
        for index in 0..<(AiQueryStore.historyLimit + 5) {
            try store.record(keyID: "busy", vendor: .openAI, prompt: "call \(index)",
                             result: ChatCompletionResult(text: "ok", model: "gpt-4o-mini", promptTokens: 1, completionTokens: 1))
        }

        XCTAssertEqual(try store.recent(keyID: "busy").count, AiQueryStore.historyLimit)
        XCTAssertEqual(try store.recent(keyID: "quiet").count, 1)
        // Newest first, and it's the newest that survives the trim.
        XCTAssertEqual(try store.recent(keyID: "busy").first?.prompt, "call \(AiQueryStore.historyLimit + 4)")
    }

    /// A transcript-sized prompt is worth recognising, not worth a second copy of.
    func testAnOversizedPromptIsStoredTrimmed() throws {
        let dbQueue = try makeDatabase()
        let store = AiQueryStore(dbQueue: dbQueue)
        try store.record(keyID: "k1", vendor: .google, prompt: String(repeating: "a", count: 10_000))

        let stored = try XCTUnwrap(store.recent(keyID: "k1").first)
        XCTAssertLessThan(stored.prompt.count, 10_000)
        XCTAssertTrue(stored.prompt.hasSuffix("…(trimmed)"))
    }
}
