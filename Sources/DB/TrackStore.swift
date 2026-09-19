import Foundation
import GRDB

struct TrackStore {
    let dbQueue: DatabaseQueue

    /// A track's real identity is (providerID, filePath) — `id` is a UUID minted by
    /// whoever imported it first. Two importers racing on the same file each mint their
    /// own, so this resolves against the natural key inside the write transaction: the
    /// second one updates the existing row instead of tripping
    /// `idx_tracks_provider_path`.
    func upsert(_ track: Track, artistName: String?, albumName: String?) throws {
        try dbQueue.write { db in
            var row = track
            if let existing = try Track
                .filter(Column("providerID") == track.providerID && Column("filePath") == track.filePath)
                .fetchOne(db), existing.id != track.id {
                row.id = existing.id
                // Playback progress and hand-made marks belong to the listener, not to
                // the import.
                row.positionMs = existing.positionMs
                row.lastPlayedAt = existing.lastPlayedAt
                row.isFavorite = existing.isFavorite
            }
            try row.save(db)
            try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [row.id])
            try db.execute(
                sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, ?, ?)",
                arguments: [row.id, row.title, artistName ?? "", albumName ?? ""]
            )
        }
    }

    /// An episode edited by hand, as opposed to one a sync found. Same write as `upsert`,
    /// plus a line in the change log: this is the half of an episode row that nothing can
    /// rebuild, and the sync path writing thousands of rows has no business in that log.
    func saveEdit(_ track: Track, artistName: String?, albumName: String?) throws {
        let old = try find(providerID: track.providerID, filePath: track.filePath)
        try upsert(track, artistName: artistName, albumName: albumName)
        ChangeLog.record("episodes", key: track.filePath, old: old, new: track, in: dbQueue)
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

    /// The episode's own language, which outranks its album's and its speaker's.
    func setLanguage(id: String, language: String?) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.language = language
            try track.update(db)
        }
    }

    func setFavorite(id: String, isFavorite: Bool) throws {
        let was: Bool? = try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return nil }
            let was = track.isFavorite
            track.isFavorite = isFavorite
            try track.update(db)
            return was
        }
        guard let was else { return }
        ChangeLog.record("episodes", key: id, old: ["isFavorite": was], new: ["isFavorite": isFavorite], in: dbQueue)
    }

    func favorites() throws -> [Track] {
        try dbQueue.read { db in
            try Track.filter(Column("isFavorite") == true && Column("isLost") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
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

    func tracks(forAlbum albumID: String) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("albumID") == albumID && Column("isLost") == false)
                .order(Column("trackNumber"), Column("title"))
                .fetchAll(db)
        }
    }

    func tracks(forArtist artistID: String) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("artistID") == artistID && Column("isLost") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }


    func tracks(forYear year: Int) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("year") == year && Column("isLost") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    /// Every synced-and-present track, for shelves that browse the whole library at once.
    func all(includingLost: Bool = false) throws -> [Track] {
        try dbQueue.read { db in
            let query = includingLost ? Track.all() : Track.filter(Column("isLost") == false)
            return try query.order(Column("title")).fetchAll(db)
        }
    }

    /// Distinct release years present in the library, newest first.
    func years() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT year FROM tracks WHERE year IS NOT NULL AND isLost = 0 ORDER BY year DESC
                """)
        }
    }

    struct ProviderStats {
        var count: Int
        var lostCount: Int
        var totalBytes: Int64
    }

    /// `pathPrefix` scopes the stats to one folder (e.g. for a per-folder readout while
    /// browsing a connection) — computed from already-collected metadata, not a live
    /// rescan of the provider.
    func stats(forProvider providerID: String, pathPrefix: String? = nil) throws -> ProviderStats {
        try dbQueue.read { db in
            let prefix = pathPrefix.flatMap { $0.isEmpty ? nil : ($0.hasSuffix("/") ? $0 : $0 + "/") }
            let likeClause = prefix != nil ? "AND filePath LIKE ?" : ""
            var arguments: [String] = [providerID]
            if let prefix { arguments.append("\(prefix)%") }

            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tracks WHERE providerID = ? AND isLost = 0 \(likeClause)",
                arguments: StatementArguments(arguments)
            ) ?? 0
            let lostCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tracks WHERE providerID = ? AND isLost = 1 \(likeClause)",
                arguments: StatementArguments(arguments)
            ) ?? 0
            let totalBytes = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM tracks WHERE providerID = ? AND isLost = 0 \(likeClause)",
                arguments: StatementArguments(arguments)
            ) ?? 0
            return ProviderStats(count: count, lostCount: lostCount, totalBytes: totalBytes)
        }
    }

    /// Every already-synced track directly under `pathPrefix` (nil/empty = the bucket root),
    /// plus the immediate subfolders below it as whole paths — the same shape
    /// `CloudProvider.listDirectory` returns, so the remote browser can fall back to this
    /// without changing how it navigates.
    func directoryListing(providerID: String, pathPrefix: String?) throws -> (folders: [String], tracks: [Track]) {
        let prefix = pathPrefix.flatMap { $0.isEmpty ? nil : ($0.hasSuffix("/") ? $0 : $0 + "/") } ?? ""
        let all = try dbQueue.read { db in
            try Track
                .filter(Column("providerID") == providerID)
                .filter(prefix.isEmpty ? Column("filePath") != nil : Column("filePath").like("\(prefix)%"))
                .order(Column("filePath"))
                .fetchAll(db)
        }

        var folders: Set<String> = []
        var tracks: [Track] = []
        for track in all {
            let relative = String(track.filePath.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            if let slashIndex = relative.firstIndex(of: "/") {
                folders.insert(prefix + relative[relative.startIndex..<slashIndex])
            } else {
                tracks.append(track)
            }
        }
        return (folders.sorted(), tracks)
    }

    /// Refreshes just the sync-derived columns for an already-known track, leaving its
    /// title/artist/album metadata (and search index) untouched.
    func refresh(id: String, sizeBytes: Int64?, contentHash: String?, remoteModifiedAt: Date?, isLost: Bool) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.sizeBytes = sizeBytes
            track.contentHash = contentHash
            track.remoteModifiedAt = remoteModifiedAt
            track.isLost = isLost
            track.updatedAt = Date()
            try track.save(db)
        }
    }

    /// Marks tracks for this provider as lost if their file path wasn't in the latest listing.
    /// Returns the number newly marked lost.
    /// Points each track at the transcript now sitting beside it, and un-points the ones
    /// whose sidecar has gone. A transcript added to a bucket later never changes the
    /// audio, so nothing else in a sync pass would ever notice it.
    func updateTranscriptPaths(providerID: String, sidecars: [String: String]) throws {
        try dbQueue.write { db in
            let tracks = try Track.filter(Column("providerID") == providerID).fetchAll(db)
            for var track in tracks {
                let found = sidecars[track.filePath]
                guard found != track.transcriptPath else { continue }
                track.transcriptPath = found
                try track.update(db)
            }
        }
    }

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
