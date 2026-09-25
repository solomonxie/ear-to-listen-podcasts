import Foundation
import GRDB

struct TrackStore {
    let dbQueue: DatabaseQueue

    /// A file's identity is (providerID, filePath) — `id` is a UUID minted by whoever
    /// imported it first. Two importers racing on the same file each mint their own, so
    /// this resolves against the natural key inside the write transaction: the second one
    /// updates the existing row instead of tripping `idx_tracks_provider_path`.
    ///
    /// **An episode's identity is the recording, not the file.** A file whose fingerprint
    /// matches one already here is the same episode arriving a second time — copied into
    /// another bucket, or sitting in this one under another name. It becomes another place
    /// that episode lives rather than a second episode, so one recording has one set of
    /// marks, one transcript and one row in every list. Which is resolved in the same
    /// transaction, and for the same reason: two sync queues draining at once.
    func upsert(_ track: Track, artistName: String?, albumName: String?) throws {
        try dbQueue.write { db in
            var row = track
            row.fingerprint = FileFingerprint.of(track)
            let atSamePath = try Track
                .filter(Column("providerID") == track.providerID && Column("filePath") == track.filePath)
                .fetchOne(db)
            if let existing = atSamePath, existing.id != track.id {
                row.id = existing.id
                // Playback progress and hand-made marks belong to the listener, not to
                // the import.
                row.positionMs = existing.positionMs
                row.lastPlayedAt = existing.lastPlayedAt
                row.isFavorite = existing.isFavorite
                row.listenLater = existing.listenLater
            } else if atSamePath == nil, try Track.fetchOne(db, key: track.id) == nil,
                      let twin = try sameRecording(as: row, in: db) {
                // A file the library has never seen, and the same recording as one it
                // has. Only a genuinely new arrival gets here: an edit being saved back
                // onto a row that already exists must never be answered by filing it
                // under some other episode.
                try Self.link(row, toTrack: twin.id, in: db)
                return
            }
            try row.save(db)
            try Self.link(row, toTrack: row.id, in: db)
            try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [row.id])
            try db.execute(
                sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, ?, ?)",
                arguments: [row.id, row.title, artistName ?? "", albumName ?? ""]
            )
        }
    }

    /// An episode already here that is this same recording under a different name or in a
    /// different bucket. Deliberately not the episode itself: the caller has already
    /// missed on (providerID, filePath), so anything this finds is a second copy.
    private func sameRecording(as track: Track, in db: Database) throws -> Track? {
        guard let fingerprint = track.fingerprint else { return nil }
        return try Track.filter(Column("fingerprint") == fingerprint && Column("id") != track.id).fetchOne(db)
    }

    /// Records where a file is, under the episode it belongs to. Written for every import,
    /// including the first — the episode's own copy is a row here too, so "every place
    /// this lives" is one query rather than a row plus a special case.
    private static func link(_ track: Track, toTrack trackID: String, in db: Database) throws {
        let existing = try TrackFile
            .filter(Column("providerID") == track.providerID && Column("filePath") == track.filePath)
            .fetchOne(db)
        var file = existing ?? TrackFile(trackID: trackID, providerID: track.providerID, filePath: track.filePath)
        file.trackID = trackID
        file.sizeBytes = track.sizeBytes
        file.contentHash = track.contentHash
        file.transcriptPath = track.transcriptPath
        file.remoteModifiedAt = track.remoteModifiedAt
        file.isLost = track.isLost
        try file.save(db)
    }

    /// An episode edited by hand, as opposed to one a sync found. Same write as `upsert`,
    /// plus a line in the change log: this is the half of an episode row that nothing can
    /// rebuild, and the sync path writing thousands of rows has no business in that log.
    func saveEdit(_ track: Track, artistName: String?, albumName: String?) throws {
        let old = try find(providerID: track.providerID, filePath: track.filePath)
        try upsert(track, artistName: artistName, albumName: albumName)
        ChangeLog.record("episodes", key: track.filePath, old: old, new: track, in: dbQueue)
    }

    /// Disconnecting a source takes its files with it — but an episode that also lives in
    /// a source still connected isn't gone, it just lives in one fewer place. Those move
    /// onto a copy that's left rather than being deleted along with everything else.
    func deleteAll(forProvider providerID: String) throws {
        try dbQueue.write { db in
            let affected = try TrackFile.filter(Column("providerID") == providerID).fetchAll(db)
            try TrackFile.filter(Column("providerID") == providerID).deleteAll(db)

            for trackID in Set(affected.map(\.trackID)) {
                guard var track = try Track.fetchOne(db, key: trackID) else { continue }
                let remaining = try TrackFile.filter(Column("trackID") == trackID).fetchAll(db)
                guard let moved = remaining.first(where: { !$0.isLost }) ?? remaining.first else {
                    try Self.forget(trackID, in: db)
                    continue
                }
                guard track.providerID == providerID else { continue }
                Self.point(&track, at: moved)
                try track.save(db)
            }

            // Rows from before an episode knew where all its copies were, and anything a
            // failed import left pointing at this source.
            let orphans = try String.fetchAll(
                db, sql: "SELECT id FROM tracks WHERE providerID = ?", arguments: [providerID]
            )
            for id in orphans { try Self.forget(id, in: db) }
        }
    }

    private static func forget(_ trackID: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [trackID])
        _ = try Track.deleteOne(db, key: trackID)
    }

    /// One copy, after a listing found it changed — or found it back. The episode follows
    /// it: if this is the copy it plays from, the episode's own columns move with it, and
    /// if the episode was lost, a copy that's returned is what it plays from now.
    func refreshCopy(_ file: TrackFile, sizeBytes: Int64?, contentHash: String?, remoteModifiedAt: Date?) throws {
        try dbQueue.write { db in
            guard var copy = try TrackFile.fetchOne(db, key: file.id) else { return }
            copy.sizeBytes = sizeBytes
            copy.contentHash = contentHash
            copy.remoteModifiedAt = remoteModifiedAt
            copy.isLost = false
            try copy.update(db)

            guard var track = try Track.fetchOne(db, key: copy.trackID) else { return }
            let isPlayedCopy = track.providerID == copy.providerID && track.filePath == copy.filePath
            guard isPlayedCopy || track.isLost else { return }
            Self.point(&track, at: copy)
            track.fingerprint = FileFingerprint.of(track)
            try track.save(db)
        }
    }

    /// Plays this episode from that copy from now on.
    private static func point(_ track: inout Track, at file: TrackFile) {
        track.providerID = file.providerID
        track.filePath = file.filePath
        track.sizeBytes = file.sizeBytes
        track.contentHash = file.contentHash
        track.transcriptPath = file.transcriptPath
        track.remoteModifiedAt = file.remoteModifiedAt
        track.isLost = file.isLost
        track.updatedAt = Date()
    }

    func all() throws -> [Track] {
        try dbQueue.read { db in try Track.fetchAll(db) }
    }

    func find(id: String) throws -> Track? {
        try dbQueue.read { db in try Track.fetchOne(db, key: id) }
    }

    /// What the episode is about, however it got written — the AI pass and the text
    /// field it lands in both come through here, so an edit and a generated one are the
    /// same kind of change.
    func setSummary(id: String, summary: String?) throws {
        let was: String?? = try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return nil }
            let was = track.summary
            track.summary = summary?.nilIfEmpty
            try track.update(db)
            return was
        }
        guard let was else { return }
        ChangeLog.record(
            "episodes", key: id,
            old: ["summary": was.map { $0.count } ?? 0], new: ["summary": summary?.count ?? 0],
            in: dbQueue
        )
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

    /// Newest first: a queue you added to is read from the end you last added at.
    func listenLater() throws -> [Track] {
        try dbQueue.read { db in
            try Track.filter(Column("listenLater") == true && Column("isLost") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    func setListenLater(id: String, listenLater: Bool) throws {
        let was: Bool? = try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return nil }
            let was = track.listenLater
            track.listenLater = listenLater
            try track.update(db)
            return was
        }
        guard let was else { return }
        ChangeLog.record("episodes", key: id, old: ["listenLater": was], new: ["listenLater": listenLater], in: dbQueue)
    }

    /// The episode stored at this file — whichever of its copies that is. A second copy
    /// isn't on the episode row, so asking `tracks` alone would answer "nothing here"
    /// about a file the library knows perfectly well, and the bucket browser would
    /// refuse to play it.
    func find(providerID: String, filePath: String) throws -> Track? {
        try dbQueue.read { db in
            if let track = try Track
                .filter(Column("providerID") == providerID && Column("filePath") == filePath)
                .fetchOne(db) { return track }
            guard let copy = try TrackFile
                .filter(Column("providerID") == providerID && Column("filePath") == filePath)
                .fetchOne(db) else { return nil }
            return try Track.fetchOne(db, key: copy.trackID)
        }
    }

    /// Every episode sitting at this path, whichever source brought it in. The provider
    /// id a backup names is the row that existed when it was written, and reconnecting a
    /// bucket after a reinstall makes a new one — so a restore that misses on the pair
    /// comes here before giving up.
    func find(filePath: String) throws -> [Track] {
        try dbQueue.read { db in
            var found = try Track.filter(Column("filePath") == filePath).fetchAll(db)
            let ids = try TrackFile.filter(Column("filePath") == filePath).fetchAll(db).map(\.trackID)
            for id in ids where !found.contains(where: { $0.id == id }) {
                if let track = try Track.fetchOne(db, key: id) { found.append(track) }
            }
            return found
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

    /// Marks tracks for this provider as lost if their file path wasn't in the latest listing.
    /// Returns the number newly marked lost.
    /// Points each track at the transcript now sitting beside it, and un-points the ones
    /// whose sidecar has gone. A transcript added to a bucket later never changes the
    /// audio, so nothing else in a sync pass would ever notice it.
    func updateTranscriptPaths(providerID: String, sidecars: [String: String]) throws {
        try dbQueue.write { db in
            // Per copy: two buckets holding the same episode can each have a transcript
            // beside it, and an upload writes over both.
            for var file in try TrackFile.filter(Column("providerID") == providerID).fetchAll(db) {
                let found = sidecars[file.filePath]
                guard found != file.transcriptPath else { continue }
                file.transcriptPath = found
                try file.update(db)
            }
            let tracks = try Track.filter(Column("providerID") == providerID).fetchAll(db)
            for var track in tracks {
                let found = sidecars[track.filePath]
                guard found != track.transcriptPath else { continue }
                track.transcriptPath = found
                try track.update(db)
            }
        }
    }

    /// Numbers apart episodes that share a title, one album at a time. Returns how many
    /// were renamed.
    ///
    /// Album by album on purpose: two collections may each hold an `Introduction`, and
    /// they aren't duplicates of each other. Tracks with no album are left alone — there's
    /// no collection to be ambiguous within.
    @discardableResult
    func numberDuplicateTitles() throws -> Int {
        try dbQueue.write { db in
            let byAlbum = Dictionary(grouping: try Track.fetchAll(db)) { $0.albumID }
            var renamed = 0
            for (albumID, tracks) in byAlbum where albumID != nil {
                for (trackID, change) in DuplicateTitles.renumbered(tracks) {
                    guard var track = try Track.fetchOne(db, key: trackID) else { continue }
                    track.title = change.title
                    track.numberedFrom = change.numberedFrom
                    // Deliberately not `metadataEditedAt` — nobody edited this, and
                    // marking it would make the next pass leave the run alone forever.
                    track.updatedAt = Date()
                    try track.update(db)
                    renamed += 1
                }
            }
            return renamed
        }
    }

    /// An episode is lost when every copy of it is. One that has gone from this bucket but
    /// still sits in another isn't missing — it moves onto the copy that's still there, so
    /// it keeps playing instead of greying out.
    func markLost(providerID: String, keepingPaths paths: Set<String>) throws -> Int {
        try dbQueue.write { db in
            let present = try TrackFile
                .filter(Column("providerID") == providerID && Column("isLost") == false)
                .fetchAll(db)
            var touched: Set<String> = []
            for var file in present where !paths.contains(file.filePath) {
                file.isLost = true
                try file.update(db)
                touched.insert(file.trackID)
            }

            var count = 0
            for trackID in touched {
                guard var track = try Track.fetchOne(db, key: trackID) else { continue }
                let copies = try TrackFile.filter(Column("trackID") == trackID).fetchAll(db)
                guard let alive = copies.first(where: { !$0.isLost }) else {
                    guard !track.isLost else { continue }
                    track.isLost = true
                    track.updatedAt = Date()
                    try track.save(db)
                    count += 1
                    continue
                }
                guard track.providerID != alive.providerID || track.filePath != alive.filePath else { continue }
                Self.point(&track, at: alive)
                try track.save(db)
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
