import Foundation
import GRDB

/// Reads and per-copy writes over `trackFiles`. Everything that has to decide something
/// about the *episode* from the state of its copies — which one it plays from, whether
/// it's lost, what happens when a source is removed — lives in `TrackStore`, where it can
/// be one transaction over both tables.
struct TrackFileStore {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) {
        self.dbQueue = dbQueue
    }

    /// Every place this episode lives, the one it plays from first.
    func all(forTrack trackID: String) throws -> [TrackFile] {
        try dbQueue.read { db in
            try TrackFile.filter(Column("trackID") == trackID).order(Column("addedAt")).fetchAll(db)
        }
    }

    /// What a sync pass asks before deciding a listed file is new: the answer covers
    /// second and third copies, which the `tracks` row alone never knew about.
    func find(providerID: String, filePath: String) throws -> TrackFile? {
        try dbQueue.read { db in
            try TrackFile
                .filter(Column("providerID") == providerID && Column("filePath") == filePath)
                .fetchOne(db)
        }
    }
}
