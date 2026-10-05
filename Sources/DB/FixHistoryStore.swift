import Foundation
import GRDB

struct FixHistoryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "fixHistory"
    var id: String = UUID().uuidString
    var at: Date = Date()
    var action: String
    var count: Int
    var detail: String?
}

/// What was done from the flagged-items page, newest first.
struct FixHistoryStore {
    let dbQueue: DatabaseQueue

    func record(action: String, count: Int, detail: String?) {
        try? dbQueue.write { db in try FixHistoryEntry(action: action, count: count, detail: detail).insert(db) }
    }

    func all() throws -> [FixHistoryEntry] {
        try dbQueue.read { db in try FixHistoryEntry.order(Column("at").desc).fetchAll(db) }
    }

    func clear() throws {
        _ = try dbQueue.write { db in try FixHistoryEntry.deleteAll(db) }
    }
}
