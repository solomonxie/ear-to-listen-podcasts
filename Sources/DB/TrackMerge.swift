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

    /// Which copy the listener would miss. Hand-edited beats untouched, then played beats
    /// unplayed, then kept beats not — and an id tiebreak so two identical rows fold the
    /// same way every time rather than by fetch order.
    private static func keepsMore(_ a: Track, _ b: Track) -> Bool {
        if (a.metadataEditedAt != nil) != (b.metadataEditedAt != nil) { return a.metadataEditedAt != nil }
        if (a.lastPlayedAt ?? .distantPast) != (b.lastPlayedAt ?? .distantPast) {
            return (a.lastPlayedAt ?? .distantPast) > (b.lastPlayedAt ?? .distantPast)
        }
        if a.isFavorite != b.isFavorite { return a.isFavorite }
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
        kept.trackNumber = keeper.trackNumber ?? duplicate.trackNumber
        kept.language = keeper.language ?? duplicate.language
        kept.artistID = keeper.artistID ?? duplicate.artistID
        kept.albumID = keeper.albumID ?? duplicate.albumID
        try kept.update(db)

        try db.execute(sql: "UPDATE trackFiles SET trackID = ? WHERE trackID = ?", arguments: [keeper.id, duplicate.id])
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
        // Cascades take whatever the moves above left behind.
        _ = try Track.deleteOne(db, key: duplicate.id)
    }
}
