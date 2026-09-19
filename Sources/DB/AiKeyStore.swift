import Foundation
import GRDB

struct AiKeyStore {
    let dbQueue: DatabaseQueue
    private let credentials = CredentialStore()

    static func secretKey(id: String) -> String { "aiKey.\(id).secret" }

    func all() throws -> [AiKey] {
        try migrateLegacyKeyIfNeeded()
        return try dbQueue.read { db in try AiKey.order(Column("position")).fetchAll(db) }
    }

    @discardableResult
    func add(vendor: AiVendor, model: String? = nil, secret: String) throws -> AiKey {
        let nextPosition = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM aiKeys") ?? 0
        }
        let key = AiKey(
            id: UUID().uuidString, vendor: vendor, model: model?.nilIfEmpty,
            position: nextPosition, createdAt: Date()
        )
        try credentials.set(secret, forKey: Self.secretKey(id: key.id))
        try dbQueue.write { db in try key.insert(db) }
        return key
    }

    /// Changes which model a key calls. Nil puts it back on the vendor default.
    func setModel(id: String, model: String?) throws {
        try dbQueue.write { db in
            guard var key = try AiKey.fetchOne(db, key: id) else { return }
            key.model = model?.nilIfEmpty
            try key.update(db)
        }
    }

    func remove(id: String) throws {
        try dbQueue.write { db in _ = try AiKey.deleteOne(db, key: id) }
        try? credentials.delete(Self.secretKey(id: id))
    }

    /// Swaps a key with its neighbor — order defines both sequential's first-try key
    /// and round-robin's cycle order.
    func move(id: String, direction: Int) throws {
        try dbQueue.write { db in
            var keys = try AiKey.order(Column("position")).fetchAll(db)
            guard let idx = keys.firstIndex(where: { $0.id == id }) else { return }
            let swapWith = idx + direction
            guard keys.indices.contains(swapWith) else { return }
            keys.swapAt(idx, swapWith)
            for (i, var key) in keys.enumerated() where key.position != i {
                key.position = i
                try key.update(db)
            }
        }
    }

    func bumpRequestCount(id: String) throws {
        try dbQueue.write { db in
            guard var key = try AiKey.fetchOne(db, key: id) else { return }
            key.requestCount += 1
            try key.update(db)
        }
    }

    func secret(forKeyID id: String) throws -> String? {
        try credentials.get(Self.secretKey(id: id))
    }

    /// One-time migration from the old single-OpenAI-key slot into the new list, the
    /// first time it's read after this feature shipped.
    private func migrateLegacyKeyIfNeeded() throws {
        let hasAny = try dbQueue.read { db in try AiKey.fetchCount(db) > 0 }
        guard !hasAny else { return }
        guard
            let legacySecret = try? credentials.get(SettingsViewModel.openAIAPIKeyKey),
            !legacySecret.isEmpty
        else { return }
        try add(vendor: .openAI, secret: legacySecret)
        try? credentials.delete(SettingsViewModel.openAIAPIKeyKey)
    }
}
