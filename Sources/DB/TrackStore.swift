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

    func find(providerID: String, filePath: String) throws -> Track? {
        try dbQueue.read { db in
            try Track.filter(Column("providerID") == providerID && Column("filePath") == filePath).fetchOne(db)
        }
    }

    func tracks(forProvider providerID: String) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("providerID") == providerID && Column("isLost") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    struct ProviderStats {
        var count: Int
        var lostCount: Int
        var totalBytes: Int64
    }

    func stats(forProvider providerID: String) throws -> ProviderStats {
        try dbQueue.read { db in
            let count = try Track
                .filter(Column("providerID") == providerID && Column("isLost") == false)
                .fetchCount(db)
            let lostCount = try Track
                .filter(Column("providerID") == providerID && Column("isLost") == true)
                .fetchCount(db)
            let totalBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM tracks WHERE providerID = ? AND isLost = 0",
                arguments: [providerID]
            ) ?? 0
            return ProviderStats(count: count, lostCount: lostCount, totalBytes: totalBytes)
        }
    }

    /// Refreshes just the sync-derived columns for an already-known track, leaving its
    /// title/artist/album metadata (and search index) untouched.
    func refresh(id: String, sizeBytes: Int64?, isLost: Bool) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.sizeBytes = sizeBytes
            track.isLost = isLost
            track.updatedAt = Date()
            try track.save(db)
        }
    }

    /// Marks tracks for this provider as lost if their file path wasn't in the latest listing.
    /// Returns the number newly marked lost.
    func markLost(providerID: String, keepingPaths paths: Set<String>) throws -> Int {
        try dbQueue.write { db in
            let candidates = try Track
                .filter(Column("providerID") == providerID && Column("isLost") == false)
                .fetchAll(db)
            var count = 0
            for var track in candidates where !paths.contains(track.filePath) {
                track.isLost = true
                track.updatedAt = Date()
                try track.save(db)
                count += 1
            }
            return count
        }
    }

    /// Records in-progress playback so it can be resumed and surfaced in "Continue Listening".
    func recordProgress(id: String, positionMs: Int, playedAt: Date = Date()) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.positionMs = positionMs
            track.lastPlayedAt = playedAt
            try track.save(db)
        }
    }

    /// Marks a track as just-started, without touching its stored resume position.
    func touchLastPlayed(id: String, playedAt: Date = Date()) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.lastPlayedAt = playedAt
            try track.save(db)
        }
    }

    /// Tracks with playback history, most recently played first.
    func recentlyPlayed(limit: Int = 20) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("lastPlayedAt") != nil && Column("isLost") == false)
                .order(Column("lastPlayedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
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
