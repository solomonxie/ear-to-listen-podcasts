import Foundation
import GRDB

/// Folds episodes that turned out to be the same file into one — the library as it stands
/// today, where the same recording was imported twice before anything checked.
///
/// New imports never reach here: `TrackStore.upsert` recognises a second copy as it
/// arrives and records it as another place one episode lives. This is the one-off for
/// everything already in the database, run by the migration that gave episodes a
/// fingerprint.
enum TrackMerge {
    /// Groups by fingerprint and folds each group onto one row. Returns how many episode
    /// rows disappeared into another.
    @discardableResult
    static func foldDuplicates(in db: Database) throws -> Int {
        let tracks = try Track.filter(sql: "fingerprint IS NOT NULL").fetchAll(db)
        var folded = 0
        for (_, group) in Dictionary(grouping: tracks, by: { $0.fingerprint ?? "" }) where group.count > 1 {
            let ordered = group.sorted(by: keepsMore)
            guard let keeper = ordered.first else { continue }
            for duplicate in ordered.dropFirst() {
                try fold(duplicate, into: keeper, in: db)
                folded += 1
            }
        }
        return folded
    }

    /// One episode whose tags were just read, against the rest: the same size and length
    /// (`FileFingerprint`); or, for an episode that lost its audio (which may have no size on
    /// record), the same file name and length, or the same collection, title and length.
    /// The listener's copy wins.
    @discardableResult
    static func foldArrival(_ trackID: String, in db: Database) throws -> Bool {
        guard let arrival = try Track.fetchOne(db, key: trackID), arrival.durationMs != nil else { return false }
        var twins: [Track] = []
        if let fingerprint = arrival.fingerprint {
            twins = try Track.filter(Column("fingerprint") == fingerprint && Column("id") != trackID).fetchAll(db)
        }
        if twins.isEmpty {
            let name = (arrival.filePath as NSString).lastPathComponent
            let candidates = try Track.fetchAll(db, sql: """
                SELECT * FROM tracks WHERE isLost = 1 AND id != ?
                  AND (filePath = ? OR filePath LIKE ? ESCAPE '\\' OR albumID = ?)
                """, arguments: [trackID, name, "%/" + escapedLike(name), arrival.albumID])
            twins = candidates.filter { isLostTwin($0, of: arrival) }
        }
        guard !twins.isEmpty else { return false }
        try fold(group: [arrival] + twins, in: db)
        return true
    }

    /// Everything already here that `foldArrival` would have caught, had it existed — the
    /// whole library read once and matched in memory, so it's seconds, not minutes.
    @discardableResult
    static func foldAll(in db: Database) throws -> Int {
        var folded = try foldDuplicates(in: db)
        let all = try Track.fetchAll(db)
        let lost = all.filter(\.isLost)
        guard !lost.isEmpty else { return folded }
        var byName: [String: [Track]] = [:]
        var byAlbumTitle: [String: [Track]] = [:]
        for track in lost {
            byName[(track.filePath as NSString).lastPathComponent, default: []].append(track)
            if let albumID = track.albumID {
                byAlbumTitle[albumID + "|" + DuplicateTitles.base(of: track.title), default: []].append(track)
            }
        }
        var gone: Set<String> = []
        for arrival in all where !arrival.isLost && arrival.durationMs != nil {
            var candidates = byName[(arrival.filePath as NSString).lastPathComponent] ?? []
            if let albumID = arrival.albumID {
                candidates += byAlbumTitle[albumID + "|" + DuplicateTitles.base(of: arrival.title)] ?? []
            }
            var seen: Set<String> = []
            let twins = candidates.filter { !gone.contains($0.id) && seen.insert($0.id).inserted && isLostTwin($0, of: arrival) }
            guard !twins.isEmpty, let fresh = try Track.fetchOne(db, key: arrival.id) else { continue }
            let group = [fresh] + twins
            try fold(group: group, in: db)
            let keeper = group.sorted(by: keepsMore).first?.id
            for member in group where member.id != keeper { gone.insert(member.id) }
            folded += twins.count
        }
        return folded
    }

    private static func isLostTwin(_ candidate: Track, of arrival: Track) -> Bool {
        guard let durationMs = arrival.durationMs else { return false }
        let closeEnough = candidate.durationMs.map { abs($0 - durationMs) <= 3_000 } ?? true
        let sameName = (candidate.filePath as NSString).lastPathComponent == (arrival.filePath as NSString).lastPathComponent
        let sameTitle = candidate.albumID != nil && candidate.albumID == arrival.albumID
            && DuplicateTitles.base(of: candidate.title) == DuplicateTitles.base(of: arrival.title)
        return closeEnough && (sameName || sameTitle)
    }

    private static func escapedLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func fold(group: [Track], in db: Database) throws {
        let ordered = group.sorted(by: keepsMore)
        guard let keeper = ordered.first else { return }
        for duplicate in ordered.dropFirst() { try fold(duplicate, into: keeper, in: db) }
    }

    /// Which copy the listener would miss. Hand-edited beats untouched, then played beats
    /// unplayed, then kept beats not — and an id tiebreak so two identical rows fold the
    /// same way every time rather than by fetch order.
    private static func keepsMore(_ a: Track, _ b: Track) -> Bool {
        if (a.metadataEditedAt != nil) != (b.metadataEditedAt != nil) { return a.metadataEditedAt != nil }
        if (a.lastPlayedAt ?? .distantPast) != (b.lastPlayedAt ?? .distantPast) {
            return (a.lastPlayedAt ?? .distantPast) > (b.lastPlayedAt ?? .distantPast)
        }
        if a.isFavorite != b.isFavorite { return a.isFavorite }
        if (a.listenedAt != nil) != (b.listenedAt != nil) { return a.listenedAt != nil }
        if (a.positionMs ?? 0) != (b.positionMs ?? 0) { return (a.positionMs ?? 0) > (b.positionMs ?? 0) }
        // The entry that was here first is the one the rest of the library points at.
        if a.isLost != b.isLost { return a.isLost }
        return a.id < b.id
    }

    /// Everything the duplicate carried moves across: where it lives, what was marked and
    /// corrected on it, and the lists it was on. `OR IGNORE` on the tables keyed by
    /// (track, something else) is the "both copies were on this playlist" case — the row
    /// is already there under the keeper, so the duplicate's is dropped rather than
    /// colliding.
    private static func fold(_ duplicate: Track, into keeper: Track, in db: Database) throws {
        var kept = keeper
        kept.isFavorite = keeper.isFavorite || duplicate.isFavorite
        kept.listenLater = keeper.listenLater || duplicate.listenLater
        if (duplicate.lastPlayedAt ?? .distantPast) > (keeper.lastPlayedAt ?? .distantPast) {
            kept.positionMs = duplicate.positionMs
            kept.lastPlayedAt = duplicate.lastPlayedAt
        }
        // Filled in only where the keeper has nothing: the keeper is the one someone
        // worked on, so its own answers stand.
        kept.notes = keeper.notes ?? duplicate.notes
        kept.summary = keeper.summary ?? duplicate.summary
        kept.artworkFileName = keeper.artworkFileName ?? duplicate.artworkFileName
        kept.year = keeper.year ?? duplicate.year
        kept.language = keeper.language ?? duplicate.language
        kept.artistID = keeper.artistID ?? duplicate.artistID
        kept.albumID = keeper.albumID ?? duplicate.albumID
        kept.durationMs = keeper.durationMs ?? duplicate.durationMs
        kept.sizeBytes = keeper.sizeBytes ?? duplicate.sizeBytes
        kept.fingerprint = keeper.fingerprint ?? duplicate.fingerprint
        kept.needsTags = keeper.needsTags && duplicate.needsTags
        kept.listenedAt = keeper.listenedAt ?? duplicate.listenedAt

        try db.execute(sql: "UPDATE trackFiles SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        // The keeper may be the copy whose bucket is gone: it plays from the arrival now.
        if kept.isLost || kept.originalDeletedAt != nil,
           let live = try TrackFile.filter(Column("trackID") == keeper.id && Column("isLost") == false).fetchOne(db) {
            kept.providerID = live.providerID
            kept.filePath = live.filePath
            kept.sizeBytes = live.sizeBytes
            kept.contentHash = live.contentHash
            kept.transcriptPath = live.transcriptPath
            kept.transcriptPaths = live.transcriptPaths
            kept.remoteModifiedAt = live.remoteModifiedAt
            kept.isLost = false
            kept.originalDeletedAt = nil
        }
        kept.updatedAt = Date()
        try db.execute(sql: "UPDATE bookmarks SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        try db.execute(sql: "UPDATE transcriptEdits SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        try db.execute(sql: "UPDATE OR IGNORE trackTerms SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        try db.execute(sql: "UPDATE OR IGNORE playlistTracks SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        // One transcript per episode, so the duplicate's is only worth taking when the
        // keeper has none — an empty page is worse than either copy.
        let hasTranscript = try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM transcripts WHERE trackID = ?)", arguments: [keeper.id]
        ) ?? false
        if !hasTranscript {
            try db.execute(sql: "UPDATE transcripts SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
        }

        try db.execute(sql: "DELETE FROM trackSearchIndex WHERE trackID = ?", arguments: [duplicate.id])
        // Cascades take whatever the moves above left behind. Gone before the keeper is
        // saved: the keeper may be taking over the duplicate's file path.
        _ = try Track.deleteOne(db, key: duplicate.id)
        try kept.update(db)
    }
}
