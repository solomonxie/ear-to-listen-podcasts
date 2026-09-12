import Foundation
import GRDB

struct TrackStore {
    let dbQueue: DatabaseQueue

    func upsert(_ track: Track, artistName: String?, albumName: String?) throws {
        try dbQueue.write { db in
            try track.save(db)
            try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [track.id])
            try db.execute(
                sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, ?, ?)",
                arguments: [track.id, track.title, artistName ?? "", albumName ?? ""]
            )
        }
    }

    func deleteAll(forProvider providerID: String) throws {
        try dbQueue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE providerID = ?", arguments: [providerID])
            if !ids.isEmpty {
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID IN (\(placeholders))", arguments: StatementArguments(ids))
            }
            try Track.filter(Column("providerID") == providerID).deleteAll(db)
        }
    }

    func all() throws -> [Track] {
        try dbQueue.read { db in try Track.fetchAll(db) }
    }

    func find(id: String) throws -> Track? {
        try dbQueue.read { db in try Track.fetchOne(db, key: id) }
    }

    func search(_ query: String) throws -> [Track] {
        guard !query.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                JOIN trackSearchIndex ON trackSearchIndex.trackID = tracks.id
                WHERE trackSearchIndex MATCH ?
                ORDER BY rank
                """, arguments: ["\(query)*"])
        }
    }
}
