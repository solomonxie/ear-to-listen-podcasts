import Foundation
import GRDB

struct ProviderStore {
    let dbQueue: DatabaseQueue

    /// Logged by type and label alone — `configJSON` holds what the Keychain doesn't, and
    /// a change log is a file, on the phone, inside every backup.
    func upsert(_ provider: ProviderRecord) throws {
        let old: ProviderRecord? = try dbQueue.write { db in
            let old = try ProviderRecord.fetchOne(db, key: provider.id)
            try provider.save(db)
            return old
        }
        ChangeLog.record(
            "sources", key: provider.id,
            old: old.map { ["type": $0.type, "label": $0.label] },
            new: ["type": provider.type, "label": provider.label], in: dbQueue
        )
    }

    func delete(id: String) throws {
        let old: ProviderRecord? = try dbQueue.write { db in
            let old = try ProviderRecord.fetchOne(db, key: id)
            _ = try ProviderRecord.deleteOne(db, key: id)
            return old
        }
        ChangeLog.record("sources", key: id, old: old.map { ["type": $0.type, "label": $0.label] }, in: dbQueue)
    }

    func all() throws -> [ProviderRecord] {
        try dbQueue.read { db in try ProviderRecord.fetchAll(db) }
    }

    func active() throws -> [ProviderRecord] {
        try dbQueue.read { db in try ProviderRecord.filter(Column("isActive") == true).fetchAll(db) }
    }

    func updateSyncFrequency(id: String, minutes: Int?) throws {
        try dbQueue.write { db in
            guard var record = try ProviderRecord.fetchOne(db, key: id) else { return }
            record.syncFrequencyMinutes = minutes
            try record.save(db)
        }
    }

    func updateLastSynced(id: String, at date: Date) throws {
        try dbQueue.write { db in
            guard var record = try ProviderRecord.fetchOne(db, key: id) else { return }
            record.lastSyncedAt = date
            try record.save(db)
        }
    }
}

struct ImportSourceStore {
    let dbQueue: DatabaseQueue

    func upsert(_ source: ImportSourceRecord) throws {
        try dbQueue.write { db in try source.save(db) }
        ChangeLog.record("importSources", key: source.id, new: ["type": source.type, "label": source.label], in: dbQueue)
    }

    func delete(id: String) throws {
        let old: ImportSourceRecord? = try dbQueue.write { db in
            let old = try ImportSourceRecord.fetchOne(db, key: id)
            _ = try ImportSourceRecord.deleteOne(db, key: id)
            return old
        }
        ChangeLog.record("importSources", key: id, old: old.map { ["type": $0.type, "label": $0.label] }, in: dbQueue)
    }

    func all() throws -> [ImportSourceRecord] {
        try dbQueue.read { db in try ImportSourceRecord.fetchAll(db) }
    }
}
