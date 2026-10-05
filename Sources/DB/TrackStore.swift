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
                row.neglectedAt = existing.neglectedAt
            } else if atSamePath == nil, try Track.fetchOne(db, key: track.id) == nil,
                      let twin = try sameRecording(as: row, in: db) {
                // A file the library has never seen, and the same recording as one it
                // has. Only a genuinely new arrival gets here: an edit being saved back
                // onto a row that already exists must never be answered by filing it
                // under some other episode.
                try Self.link(row, toTrack: twin.id, in: db)
                // The episode had no copy left anywhere — history and notes stayed on
                // the row, waiting. This is that copy: play from it again.
                if twin.isLost, var revived = try Track.fetchOne(db, key: twin.id),
                   let copy = try TrackFile
                       .filter(Column("providerID") == row.providerID && Column("filePath") == row.filePath)
                       .fetchOne(db) {
                    Self.point(&revived, at: copy)
                    try revived.save(db)
                }
                return
            }
            if row.neglectedAt == nil, try Self.parentIsNeglected(row, in: db) { row.neglectedAt = Date() }
            try row.save(db)
            try Self.link(row, toTrack: row.id, in: db)
            try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [row.id])
            try db.execute(
                sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, ?, ?)",
                arguments: [row.id, row.title, artistName ?? "", albumName ?? ""]
            )
        }
    }

    private static func parentIsNeglected(_ track: Track, in db: Database) throws -> Bool {
        if let id = track.albumID, try Album.fetchOne(db, key: id)?.neglectedAt != nil { return true }
        if let id = track.artistID, try Artist.fetchOne(db, key: id)?.neglectedAt != nil { return true }
        return false
    }

    /// An episode already here that is this same recording under a different name or in a
    /// different bucket. Deliberately not the episode itself: the caller has already
    /// missed on (providerID, filePath), so anything this finds is a second copy.
    private func sameRecording(as track: Track, in db: Database) throws -> Track? {
        if let fingerprint = track.fingerprint,
           let match = try Track.filter(Column("fingerprint") == fingerprint && Column("id") != track.id).fetchOne(db) {
            return match
        }
        // Same provider hash and byte count, straight off the listing — no duration needed,
        // so a new bucket's file is recognized before anything is downloaded. Lost rows
        // only: between live copies the fingerprint stays the rule.
        if let parked = try Track.filter(
            Column("providerID") == OrphanedEpisodes.providerID
                && Column("filePath") == OrphanedEpisodes.path(originalProviderID: track.providerID, originalFilePath: track.filePath)
        ).fetchOne(db) { return parked }
        guard let hash = track.contentHash, !hash.isEmpty, let size = track.sizeBytes, size > 0 else { return nil }
        return try Track.filter(
            Column("contentHash") == hash && Column("sizeBytes") == size
                && Column("isLost") == true && Column("id") != track.id
        ).fetchOne(db)
    }

    /// An episode with no audio whose provider hash and byte count match this file: the file
    /// becomes the episode's copy and it plays again. False when nothing matches.
    func relinkLostEpisode(to file: TrackFile) throws -> Bool {
        try dbQueue.write { db in try Self.relink(file, in: db) }
    }

    private static func relink(_ file: TrackFile, in db: Database) throws -> Bool {
        // A restore parked it under this very bucket and path; or the same ETag and size.
        var parked = try Track.filter(
            Column("providerID") == OrphanedEpisodes.providerID
                && Column("filePath") == OrphanedEpisodes.path(originalProviderID: file.providerID, originalFilePath: file.filePath)
        ).fetchOne(db)
        if parked == nil, let hash = file.contentHash, !hash.isEmpty, let size = file.sizeBytes, size > 0 {
            parked = try Track.filter(
                Column("contentHash") == hash && Column("sizeBytes") == size && Column("isLost") == true
            ).fetchOne(db)
        }
        guard var lost = parked else { return false }
        var copy = file
        copy.trackID = lost.id
        try copy.save(db)
        point(&lost, at: copy)
        lost.fingerprint = FileFingerprint.of(lost)
        try lost.save(db)
        return true
    }

    /// The scan half of a sync: one entry per listed file, from the listing alone — name,
    /// size, ETag, nothing read from the file — all in one transaction. Tags follow in
    /// the background (`needingTags`). A file that is a lost episode coming back re-links
    /// instead. Returns how many were new.
    @discardableResult
    func registerListed(_ files: [CloudFile], providerID: String, sidecars: [String: [String]]) throws -> Int {
        try dbQueue.write { db in
            var added = 0
            var existing = Set(try String.fetchAll(
                db, sql: "SELECT filePath FROM trackFiles WHERE providerID = ?", arguments: [providerID]
            ))
            for file in files where existing.insert(file.path).inserted {
                let paths = sidecars[file.path]
                let copy = TrackFile(
                    trackID: "", providerID: providerID, filePath: file.path, sizeBytes: file.sizeBytes,
                    contentHash: file.contentHash, transcriptPath: paths?.first, transcriptPaths: paths,
                    remoteModifiedAt: file.modifiedAt
                )
                if try Self.relink(copy, in: db) { continue }
                let stem = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
                let track = Track(
                    id: UUID().uuidString, providerID: providerID, filePath: file.path, title: stem,
                    sizeBytes: file.sizeBytes, contentHash: file.contentHash, transcriptPath: paths?.first,
                    transcriptPaths: paths, remoteModifiedAt: file.modifiedAt, updatedAt: Date(), needsTags: true
                )
                try track.insert(db)
                try Self.link(track, toTrack: track.id, in: db)
                try db.execute(
                    sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, '', '')",
                    arguments: [track.id, track.title]
                )
                added += 1
            }
            return added
        }
    }

    /// Entries still waiting for their tags, not counting `excluding` (ones that failed
    /// this pass). Lost entries have nothing to read from.
    func needingTags(limit: Int, excluding: Set<String>) throws -> [Track] {
        try dbQueue.read { db in
            let rows = try Track.filter(Column("needsTags") == true && Column("isLost") == false)
                .limit(limit + excluding.count).fetchAll(db)
            return Array(rows.filter { !excluding.contains($0.id) }.prefix(limit))
        }
    }

    func needsTagsCount() throws -> Int {
        try dbQueue.read { db in
            try Track.filter(Column("needsTags") == true && Column("isLost") == false).fetchCount(db)
        }
    }

    func setPrefersVoice(id: String, _ prefersVoice: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET prefersVoice = ? WHERE id = ?", arguments: [prefersVoice, id])
        }
    }

    /// After its file was deleted from the bucket by the listener: no copies left to sync,
    /// and the voice track plays from now on.
    func markOriginalDeleted(id: String) throws {
        try dbQueue.write { db in
            try TrackFile.filter(Column("trackID") == id).deleteAll(db)
            try db.execute(
                sql: "UPDATE tracks SET originalDeletedAt = ?, prefersVoice = 1, isLost = 0 WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// Asks for these entries' tags to be read again (`SourceRefresh`).
    func markNeedsTags(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids { try db.execute(sql: "UPDATE tracks SET needsTags = 1 WHERE id = ?", arguments: [id]) }
            try db.execute(sql: """
                DELETE FROM syncJobs WHERE kind = 'readTags' AND status IN ('failed', 'done') AND trackID IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(ids))
        }
    }

    /// Clears the flag for entries that can't be read (lost, or their source is gone).
    func clearNeedsTags(ids: [String]) throws {
        try dbQueue.write { db in
            for id in ids { try db.execute(sql: "UPDATE tracks SET needsTags = 0 WHERE id = ?", arguments: [id]) }
        }
    }

    /// The tag half: what was read from the file, applied to its entry. A title someone
    /// has since edited by hand is left alone.
    func applyTags(
        id: String, title: String?, durationMs: Int?, year: Int?, artistName: String?, albumName: String?
    ) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            let artist = try artistName.map { name -> Artist in
                if let found = try Artist.filter(Column("name") == name).fetchOne(db) { return found }
                let created = Artist(id: UUID().uuidString, name: name)
                try created.insert(db)
                return created
            }
            let album = try albumName.map { name -> Album in
                if let found = try Album.filter(Column("name") == name && Column("artistID") == artist?.id).fetchOne(db) {
                    return found
                }
                var created = Album(id: UUID().uuidString, artistID: artist?.id, name: name)
                created.neglectedAt = artist?.neglectedAt
                try created.insert(db)
                return created
            }
            if track.metadataEditedAt == nil, let title, !title.isEmpty { track.title = title }
            track.durationMs = durationMs ?? track.durationMs
            track.year = year ?? track.year
            track.artistID = track.artistID ?? artist?.id
            track.albumID = track.albumID ?? album?.id
            track.fingerprint = FileFingerprint.of(track)
            track.needsTags = false
            if track.neglectedAt == nil, try Self.parentIsNeglected(track, in: db) { track.neglectedAt = Date() }
            track.updatedAt = Date()
            try track.update(db)
            try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [id])
            try db.execute(
                sql: "INSERT INTO trackSearchIndex(trackID, title, artist, album) VALUES (?, ?, ?, ?)",
                arguments: [id, track.title, artist?.name ?? "", album?.name ?? ""]
            )
            // Now that its length is known, it may turn out to be an episode already here.
            try TrackMerge.foldArrival(id, in: db)
        }
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
        file.transcriptPaths = track.transcriptPaths
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
    ///
    /// An episode with no copy left anywhere is marked lost, not deleted: the history and
    /// notes on its row are the listener's, not the sync's, and the only thing this source
    /// going away actually costs is the ability to play it. If the same recording turns up
    /// in another bucket later, `upsert`'s fingerprint match finds this row and plays from
    /// there again.
    func deleteAll(forProvider providerID: String) throws {
        try dbQueue.write { db in
            let affected = try TrackFile.filter(Column("providerID") == providerID).fetchAll(db)
            try TrackFile.filter(Column("providerID") == providerID).deleteAll(db)

            for trackID in Set(affected.map(\.trackID)) {
                guard var track = try Track.fetchOne(db, key: trackID) else { continue }
                let remaining = try TrackFile.filter(Column("trackID") == trackID).fetchAll(db)
                guard let moved = remaining.first(where: { !$0.isLost }) ?? remaining.first else {
                    try Self.markOrphaned(&track, in: db)
                    continue
                }
                guard track.providerID == providerID else { continue }
                Self.point(&track, at: moved)
                try track.save(db)
            }

            // Rows from before an episode knew where all its copies were, and anything a
            // failed import left pointing at this source.
            let orphans = try Track.filter(Column("providerID") == providerID).fetchAll(db)
            for var track in orphans { try Self.markOrphaned(&track, in: db) }
        }
    }

    /// No copy left anywhere: still a row, still lost, so the listener's marks on it are
    /// never cascade-deleted along with a bucket. Repointed at the standing "orphaned"
    /// provider row rather than left on the one about to be deleted — `tracks.providerID`
    /// cascades on that row's deletion, and this is what keeps the cascade from reaching it.
    private static func markOrphaned(_ track: inout Track, in db: Database) throws {
        guard track.providerID != OrphanedEpisodes.providerID else { return }
        track.filePath = OrphanedEpisodes.path(originalProviderID: track.providerID, originalFilePath: track.filePath)
        track.providerID = OrphanedEpisodes.providerID
        track.isLost = true
        track.updatedAt = Date()
        try track.save(db)
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
            guard isPlayedCopy || track.isLost || track.isVideoOnly else { return }
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
        track.transcriptPaths = file.transcriptPaths
        track.remoteModifiedAt = file.remoteModifiedAt
        track.isLost = file.isLost
        track.updatedAt = Date()
    }

    private static var shown: SQLSpecificExpressible { Column("neglectedAt") == nil }

    func all() throws -> [Track] {
        try dbQueue.read { db in try Track.filter(Self.shown).fetchAll(db) }
    }

    func find(id: String) throws -> Track? {
        try dbQueue.read { db in try Track.fetchOne(db, key: id) }
    }

    /// Many rows in one query, keyed by id.
    func find(ids: [String]) throws -> [String: Track] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Track.fetchAll(db, keys: ids)
            return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
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
            try Track.filter(Column("isFavorite") == true && Column("isLost") == false && Self.shown)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    /// Newest first: a queue you added to is read from the end you last added at.
    func listenLater() throws -> [Track] {
        try dbQueue.read { db in
            try Track.filter(Column("listenLater") == true && Column("isLost") == false && Self.shown)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Marks episodes listened (now) or not, in one write — an album's worth at once from
    /// its page, one at a time everywhere else. An episode already marked keeps its date.
    func setListened(ids: [String], listened: Bool) throws {
        guard !ids.isEmpty else { return }
        let now = Date()
        try dbQueue.write { db in
            for var track in try Track.fetchAll(db, keys: ids) {
                let wanted: Date? = listened ? (track.listenedAt ?? now) : nil
                guard wanted != track.listenedAt else { continue }
                track.listenedAt = wanted
                try track.update(db)
            }
        }
        for id in ids {
            ChangeLog.record("episodes", key: id, new: ["listened": listened], in: dbQueue)
        }
    }

    /// Most recently finished first.
    func listened() throws -> [Track] {
        try dbQueue.read { db in
            try Track.filter(Column("listenedAt") != nil && Column("isLost") == false && Self.shown)
                .order(Column("listenedAt").desc)
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
                .filter(Column("providerID") == providerID && Column("isLost") == false && Self.shown)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    /// Ordered in Swift rather than by `ORDER BY`: SQLite compares filenames byte by byte,
    /// which puts `ep-10` before `ep-9` — see `EpisodeOrder`.
    ///
    /// `includingLost` is for browsing, not playing: a play queue or CarPlay's list filling
    /// itself with episodes that have nothing left to stream would just hand the player an
    /// item it can only fail on. The album page is where a listener goes looking for an
    /// episode's notes long after its bucket is gone, so that's the one place this is true.
    func tracks(forAlbum albumID: String, includingLost: Bool = false) throws -> [Track] {
        try dbQueue.read { db in
            EpisodeOrder.ordered(
                try Self.filtered(Track.filter(Column("albumID") == albumID), includingLost: includingLost)
                    .fetchAll(db)
            )
        }
    }

    /// See `tracks(forAlbum:includingLost:)`.
    func tracks(forArtist artistID: String, includingLost: Bool = false) throws -> [Track] {
        try dbQueue.read { db in
            try Self.filtered(Track.filter(Column("artistID") == artistID), includingLost: includingLost)
                .order(Column("title"))
                .fetchAll(db)
        }
    }


    func tracks(forYear year: Int) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("year") == year && Column("isLost") == false && Self.shown)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    private static func filtered(
        _ query: QueryInterfaceRequest<Track>, includingLost: Bool
    ) -> QueryInterfaceRequest<Track> {
        (includingLost ? query : query.filter(Column("isLost") == false)).filter(shown)
    }

    /// Every synced-and-present track, for shelves that browse the whole library at once.
    func all(includingLost: Bool = false) throws -> [Track] {
        try dbQueue.read { db in
            let query = (includingLost ? Track.all() : Track.filter(Column("isLost") == false)).filter(Self.shown)
            return try query.order(Column("title")).fetchAll(db)
        }
    }

    /// Distinct release years present in the library, newest first.
    func years() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT year FROM tracks WHERE year IS NOT NULL AND isLost = 0 AND neglectedAt IS NULL ORDER BY year DESC
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
    ///
    /// Takes every language's file per episode (`TranscriptFile.sidecarSetsByAudioPath`);
    /// the first is also kept as `transcriptPath`.
    func updateTranscriptPaths(providerID: String, sidecars: [String: [String]]) throws {
        try dbQueue.write { db in
            // Per copy: two buckets holding the same episode can each have a transcript
            // beside it, and an upload writes over both.
            for var file in try TrackFile.filter(Column("providerID") == providerID).fetchAll(db) {
                let found = sidecars[file.filePath]
                guard found != file.transcriptPaths || found?.first != file.transcriptPath else { continue }
                file.transcriptPath = found?.first
                file.transcriptPaths = found
                try file.update(db)
            }
            let tracks = try Track.filter(Column("providerID") == providerID).fetchAll(db)
            for var track in tracks {
                let found = sidecars[track.filePath]
                guard found != track.transcriptPaths || found?.first != track.transcriptPath else { continue }
                track.transcriptPath = found?.first
                track.transcriptPaths = found
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

    /// The episodes behind the `flagged()` count, each with what's wrong.
    func flaggedItems() throws -> [FlaggedEpisodes.Item] {
        let transcribed = try TranscriptStore(dbQueue: dbQueue).transcribedTrackIDs()
        let tracks = try dbQueue.read { db in try Track.filter(Self.shown).order(Column("title")).fetchAll(db) }
        return tracks.compactMap { track in
            let reasons = FlaggedEpisodes.reasons(for: track, hasTranscript: transcribed.contains(track.id))
            return reasons.isEmpty ? nil : FlaggedEpisodes.Item(track: track, reasons: reasons)
        }
    }

    /// What the library still can't say about its episodes — see `FlaggedEpisodes`.
    func flagged() throws -> FlaggedEpisodes.Summary {
        let transcribed = try TranscriptStore(dbQueue: dbQueue).transcribedTrackIDs()
        let tracks = try dbQueue.read { db in
            try Track.filter(Self.shown).fetchAll(db)
        }
        return FlaggedEpisodes.summary(tracks: tracks, transcribed: transcribed)
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
                    .sorted { ($0.providerID == YouTubeVideo.providerID ? 1 : 0) < ($1.providerID == YouTubeVideo.providerID ? 1 : 0) }
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

    func setDuration(id: String, durationMs: Int) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET durationMs = ? WHERE id = ?", arguments: [durationMs, id])
        }
    }

    /// For episodes that are only a row — a YouTube video — never a file a sync found.
    func delete(id: String) throws {
        try dbQueue.write { db in try Self.forget(id, in: db) }
    }

    /// Every row, hidden or lost — what a backup has to hold.
    func everything() throws -> [Track] {
        try dbQueue.read { db in try Track.fetchAll(db) }
    }

    /// Hidden episodes included — for deleting a whole album or speaker.
    func trackIDs(albumID: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE albumID = ?", arguments: [albumID]) }
    }

    func trackIDs(artistID: String) throws -> [String] {
        try dbQueue.read { db in try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE artistID = ?", arguments: [artistID]) }
    }

    func setNeglected(ids: [String], neglected: Bool) throws {
        guard !ids.isEmpty else { return }
        let stamp: Date? = neglected ? Date() : nil
        try dbQueue.write { db in
            for var track in try Track.fetchAll(db, keys: ids) {
                track.neglectedAt = stamp
                try track.update(db)
            }
        }
    }

    /// Episodes hidden on their own — not just because their album or speaker is.
    func neglectedEpisodes() throws -> [Track] {
        try dbQueue.read { db in
            try Track.fetchAll(db, sql: """
                SELECT tracks.* FROM tracks
                LEFT JOIN albums ON albums.id = tracks.albumID
                LEFT JOIN artists ON artists.id = tracks.artistID
                WHERE tracks.neglectedAt IS NOT NULL
                  AND albums.neglectedAt IS NULL AND artists.neglectedAt IS NULL
                ORDER BY tracks.title
                """)
        }
    }

    /// Paths this source's neglected episodes live at, so a sync can leave them alone.
    func neglectedPaths(providerID: String) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT trackFiles.filePath FROM trackFiles
                JOIN tracks ON tracks.id = trackFiles.trackID
                WHERE trackFiles.providerID = ? AND tracks.neglectedAt IS NOT NULL
                """, arguments: [providerID]))
        }
    }

    /// Batch fix for the `noAudio` flag: removes every episode with no copy left, marks and
    /// notes included.
    @discardableResult
    func deleteLost() throws -> Int {
        try dbQueue.write { db in
            let ids = try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE isLost = 1 AND neglectedAt IS NULL")
            for id in ids { try Self.forget(id, in: db) }
            return ids.count
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

    /// Newest added first.
    func youTubeEpisodes() throws -> [Track] {
        try dbQueue.read { db in
            try Track.filter(Column("youTubeVideoID") != nil)
                .order(Column("rowid").desc)
                .fetchAll(db)
        }
    }

    func find(youTubeVideoID videoID: String) throws -> Track? {
        try dbQueue.read { db in try Track.filter(Column("youTubeVideoID") == videoID).fetchOne(db) }
    }

    /// An audio file for a YouTube episode — named with its video ID — becomes another
    /// place that episode lives, and the one it plays from: a file plays in the
    /// background, on the lock screen and in the car, where the video can't.
    func attach(_ copy: TrackFile, toYouTubeEpisode trackID: String) throws {
        try dbQueue.write { db in
            guard var track = try Track.fetchOne(db, key: trackID) else { return }
            var file = copy
            file.trackID = trackID
            try file.save(db)
            guard track.isVideoOnly || track.isLost else { return }
            Self.point(&track, at: file)
            try track.save(db)
        }
    }

    /// Every episode ever played — all that `SpeakerOrder` looks at.
    func played() throws -> [Track] {
        try dbQueue.read { db in try Track.filter(Column("lastPlayedAt") != nil && Self.shown).fetchAll(db) }
    }

    /// Tracks with playback history, most recently played first.
    func recentlyPlayed(limit: Int = 20) throws -> [Track] {
        try dbQueue.read { db in
            try Track
                .filter(Column("lastPlayedAt") != nil && Column("isLost") == false && Self.shown)
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
                WHERE trackSearchIndex MATCH ? AND tracks.neglectedAt IS NULL
                ORDER BY rank
                """, arguments: ["\(query)*"])
        }
    }
}
