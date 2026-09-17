import Foundation
import GRDB

/// A restored archive that hasn't fully landed yet.
///
/// A reinstall restores before anything has synced, so the half of the backup that hangs
/// off real episode files — playlist track order, hand edits, transcripts — has nothing
/// to attach to at the moment it arrives. Rather than telling the listener to come back
/// and restore a second time after the first sync, the archive waits here and is
/// re-applied every time a sync brings more files in, until nothing is left waiting.
enum PendingRestore {
    /// Long enough for a big library to finish syncing, short enough that a backup nobody
    /// ever synced against stops re-applying itself to a library that has moved on.
    private static let expiry: TimeInterval = 30 * 24 * 60 * 60

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "pending-restore.zip")
    }

    static func save(_ archive: Data) {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? archive.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Links up whatever the files just synced now make matchable. Only the parts that
    /// need a track — sources, playlists and speakers the first pass already created are
    /// left alone, so anything deleted since the restore stays deleted.
    static func reapplyAfterSync(dbQueue: DatabaseQueue) {
        guard let archive = try? Data(contentsOf: fileURL) else { return }
        let age = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate)
            .map { Date().timeIntervalSince($0) } ?? 0
        guard age < expiry else { return clear() }

        let service = BackupService(dbQueue: dbQueue)
        guard let snapshot = try? service.unarchive(archive),
              let result = try? service.apply(snapshot, scope: .needsSyncedTracks)
        else { return }
        if result.awaitingSync == 0 { clear() }
    }
}
