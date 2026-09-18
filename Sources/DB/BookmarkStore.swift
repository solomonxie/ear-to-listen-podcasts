import Foundation
import GRDB

struct BookmarkStore {
    let dbQueue: DatabaseQueue

    @discardableResult
    func add(trackID: String, positionMs: Int, transcriptText: String? = nil) throws -> Bookmark {
        let bookmark = Bookmark(
            id: UUID().uuidString, trackID: trackID, positionMs: positionMs,
            note: nil, tags: nil, transcriptText: transcriptText, createdAt: Date()
        )
        try dbQueue.write { db in try bookmark.insert(db) }
        return bookmark
    }

    func update(_ bookmark: Bookmark) throws {
        try dbQueue.write { db in try bookmark.update(db) }
    }

    func delete(id: String) throws {
        _ = try dbQueue.write { db in try Bookmark.deleteOne(db, key: id) }
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

    /// Newest first — how Home shows them, since a bookmark is a thing to come back to.
    func recent(limit: Int = 30) throws -> [Bookmark] {
        try dbQueue.read { db in
            try Bookmark.order(Column("createdAt").desc).limit(limit).fetchAll(db)
        }
    }
}
