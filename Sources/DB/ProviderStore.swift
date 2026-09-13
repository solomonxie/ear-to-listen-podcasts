import Foundation
import GRDB

struct ProviderStore {
    let dbQueue: DatabaseQueue

    func upsert(_ provider: ProviderRecord) throws {
        try dbQueue.write { db in try provider.save(db) }
    }

    func delete(id: String) throws {
        try dbQueue.write { db in _ = try ProviderRecord.deleteOne(db, key: id) }
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
    }

    func delete(id: String) throws {
        try dbQueue.write { db in _ = try ImportSourceRecord.deleteOne(db, key: id) }
    }

    func all() throws -> [ImportSourceRecord] {
        try dbQueue.read { db in try ImportSourceRecord.fetchAll(db) }
    }
}
