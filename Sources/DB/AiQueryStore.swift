import Foundation
import GRDB

struct AiQueryStore {
    /// Enough to see a pattern, few enough that nobody's database grows on AI history.
    /// Trimmed per key, not globally, so a rarely-used key keeps its own story.
    static let historyLimit = 100

    let dbQueue: DatabaseQueue

    @discardableResult
    func record(
        keyID: String, vendor: AiVendor, prompt: String,
        result: ChatCompletionResult? = nil, error: Error? = nil, fallbackModel: String = "unknown"
    ) throws -> AiQuery {
        let query = AiQuery(
            id: UUID().uuidString,
            keyID: keyID,
            vendor: vendor,
            model: result?.model ?? fallbackModel,
            prompt: AiQuery.trimmed(prompt),
            response: result.map { AiQuery.trimmed($0.text) },
            errorMessage: error?.localizedDescription,
            promptTokens: result?.promptTokens,
            completionTokens: result?.completionTokens,
            createdAt: Date()
        )
        try dbQueue.write { db in
            try query.insert(db)
            // `rowid` breaks the tie: several calls can land in the same stored
            // millisecond, and on `createdAt` alone the trim would sometimes drop the
            // newest of them.
            try db.execute(sql: """
                DELETE FROM aiQueries WHERE keyID = ? AND id NOT IN (
                    SELECT id FROM aiQueries WHERE keyID = ? ORDER BY createdAt DESC, rowid DESC LIMIT ?
                )
                """, arguments: [keyID, keyID, Self.historyLimit])
        }
        return query
    }

    func recent(keyID: String) throws -> [AiQuery] {
        try dbQueue.read { db in
            try AiQuery.fetchAll(
                db,
                sql: "SELECT * FROM aiQueries WHERE keyID = ? ORDER BY createdAt DESC, rowid DESC",
                arguments: [keyID]
            )
        }
    }

    func removeAll(keyID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM aiQueries WHERE keyID = ?", arguments: [keyID])
        }
    }
}
