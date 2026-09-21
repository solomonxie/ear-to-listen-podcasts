import Foundation
import GRDB

struct BookmarkStore {
    let dbQueue: DatabaseQueue

    /// A second is as fine as a mark gets: the list shows whole seconds, so two rows both
    /// reading 12:03 are one mark made twice — a double tap, or a second thought a moment
    /// later. The mark already there comes back instead of a new one, which leaves the
    /// caller free to scroll to and highlight it exactly as it would a fresh one.
    @discardableResult
    func add(trackID: String, positionMs: Int, transcriptText: String? = nil) throws -> Bookmark {
        if let existing = try existing(trackID: trackID, inSecondOf: positionMs) { return existing }
        let bookmark = Bookmark(
            id: UUID().uuidString, trackID: trackID, positionMs: positionMs,
            note: nil, tags: nil, transcriptText: transcriptText, createdAt: Date()
        )
        try dbQueue.write { db in try bookmark.insert(db) }
        ChangeLog.record("bookmarks", key: bookmark.id, new: bookmark, in: dbQueue)
        return bookmark
    }

    private func existing(trackID: String, inSecondOf positionMs: Int) throws -> Bookmark? {
        let second = (positionMs / 1000) * 1000
        return try dbQueue.read { db in
            try Bookmark
                .filter(Column("trackID") == trackID)
                .filter(Column("positionMs") >= second && Column("positionMs") < second + 1000)
                .fetchOne(db)
        }
    }

    func update(_ bookmark: Bookmark) throws {
        let old: Bookmark? = try dbQueue.write { db in
            let old = try Bookmark.fetchOne(db, key: bookmark.id)
            try bookmark.update(db)
            return old
        }
        ChangeLog.record("bookmarks", key: bookmark.id, old: old, new: bookmark, in: dbQueue)
    }

    func delete(id: String) throws {
        let old: Bookmark? = try dbQueue.write { db in
            let old = try Bookmark.fetchOne(db, key: id)
            _ = try Bookmark.deleteOne(db, key: id)
            return old
        }
        ChangeLog.record("bookmarks", key: id, old: old, in: dbQueue)
    }

    /// In episode order, which is the order they're listened back in.
    func all(forTrack trackID: String) throws -> [Bookmark] {
        try dbQueue.read { db in
            try Bookmark.filter(Column("trackID") == trackID).order(Column("positionMs")).fetchAll(db)
        }
    }

    func all(forTracks trackIDs: [String]) throws -> [Bookmark] {
        guard !trackIDs.isEmpty else { return [] }
        return try dbQueue.read { db in
            try Bookmark.filter(trackIDs.contains(Column("trackID")))
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Every mark, newest first. For the full bookmarks page — `recent` is what Home
    /// reads, and its limit is why that page can't just be handed Home's copy.
    func all() throws -> [Bookmark] {
        try dbQueue.read { db in try Bookmark.order(Column("createdAt").desc).fetchAll(db) }
    }

    /// Newest first — how Home shows them, since a bookmark is a thing to come back to.
    func recent(limit: Int = 30) throws -> [Bookmark] {
        try dbQueue.read { db in
            try Bookmark.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }
}
