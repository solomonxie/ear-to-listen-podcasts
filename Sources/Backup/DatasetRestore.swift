import Foundation
import GRDB

/// Putting an archive back, without the library it lands on being the thing at risk.
///
/// **Onto a library with episodes in it, the archive is merged in** (`BackupService.apply`,
/// which only ever fills in what isn't there). A swap would be the destructive move here:
/// an archive carries no episodes or albums — a sync rebuilds those — so replacing a
/// working library with one costs every episode on screen and the source row that knows
/// how to fetch them back, to put back edits that could have landed exactly where they
/// were. The tier-1 copies are taken first either way, so "that was the wrong archive" is
/// still one button.
///
/// **Onto an empty library it builds a new dataset** — an empty, migrated database of its
/// own — fills it from the archive, and only then puts it in place. Nothing of the live
/// library is touched until that has all worked. With nothing on screen to lose, this is
/// the cleaner of the two: playlists and sources come back under the ids the archive
/// names, rather than merging into whatever a half-finished sync has made so far.
///
/// The swap goes through the connection the app already holds (`replaceContents(with:)`)
/// rather than pointing everything at a new file, so nothing is left reading a database
/// nobody writes to any more.
///
/// The one restore that doesn't come through here is `FirstRunRestore`: on a fresh install
/// there is nothing to overwrite, nothing to undo, and nobody to ask.
enum DatasetRestore {
    private static let previousKey = "backup.restore.previousLibrary"
    private static let previousAtKey = "backup.restore.previousAt"

    /// The library a restore replaced, while it's still around to go back to. Nil once the
    /// seven-day prune has taken it, which is also when the offer to undo disappears.
    static var previousLibrary: (url: URL, at: Date)? {
        guard let name = UserDefaults.standard.string(forKey: previousKey),
              let at = UserDefaults.standard.object(forKey: previousAtKey) as? Date
        else { return nil }
        let url = LocalBackups.snapshotsDirectory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, at)
    }

    /// Puts `archive` back — merged into the library that's here, or swapped in as a
    /// dataset of its own if there isn't one. Returns what landed and what's waiting on
    /// a sync.
    @discardableResult
    static func restore(_ archive: Data) throws -> BackupImportResult {
        let live = BackupService()
        let snapshot = try live.unarchive(archive)
        // An archive of an empty library is what a wipe leaves behind, and it decodes
        // perfectly well. Swapping it in is a wipe dressed as a restore.
        guard !snapshot.isEmpty else { throw BackupError.emptyBackup }

        // Both copies of what's about to change: the zip for anywhere, the database file
        // for here — a swap back, with no matching or re-linking in between.
        if let current = try? live.currentArchive() {
            LocalBackups.writeBefore("restore", archive: current)
        }
        let preservedName = (BackupArchiveName.beforeOperation("restore") as NSString).deletingPathExtension + ".sqlite"
        let preserved = LocalBackups.copyDatabase(named: preservedName)

        let result = try hasALibrary() ? live.apply(snapshot) : swapIn(snapshot)
        if let preserved {
            UserDefaults.standard.set(preserved.lastPathComponent, forKey: previousKey)
            UserDefaults.standard.set(Date(), forKey: previousAtKey)
        }
        // Whatever named an episode this device hasn't fetched yet waits here and is
        // re-applied after each sync — on an empty library, that's all of it.
        if result.awaitingSync > 0 { PendingRestore.save(archive) } else { PendingRestore.clear() }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return result
    }

    /// Whether there is anything on screen to lose. A library part-way through its first
    /// sync counts: those episodes are what the archive's edits attach to.
    private static func hasALibrary() throws -> Bool {
        let dbQueue = DatabaseManager.shared.dbQueue
        return try !TrackStore(dbQueue: dbQueue).all(includingLost: true).isEmpty
            || !PlaylistStore(dbQueue: dbQueue).all().isEmpty
    }

    /// The archive into a database of its own, then that database into place. Only onto an
    /// empty library, where there is nothing the swap can take away.
    private static func swapIn(_ snapshot: LibrarySnapshot) throws -> BackupImportResult {
        let stagingURL = URL.applicationSupportDirectory.appending(path: "restoring.sqlite")
        remove(stagingURL)
        defer { remove(stagingURL) }
        let staged = try DatabaseManager.makeDataset(at: stagingURL)
        let result = try BackupService(dbQueue: staged).apply(snapshot)
        try DatabaseManager.shared.replaceContents(with: staged)
        return result
    }

    /// Puts back the library the last restore replaced. The restored one goes into the
    /// same kept-aside folder on the way past, so undoing an undo is also possible.
    static func undo() throws {
        guard let previous = previousLibrary else { return }
        LocalBackups.copyDatabase(named: (BackupArchiveName.beforeOperation("undo") as NSString).deletingPathExtension + ".sqlite")
        let restored = try DatabaseQueue(path: previous.url.path)
        try DatabaseManager.shared.replaceContents(with: restored)
        PendingRestore.clear()
        UserDefaults.standard.removeObject(forKey: previousKey)
        UserDefaults.standard.removeObject(forKey: previousAtKey)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// The sidecars go too — a half-deleted database is one SQLite will happily reopen.
    private static func remove(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
