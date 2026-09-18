import Foundation
import GRDB

/// Putting an archive back, without the library it lands on being the thing at risk.
///
/// A restore builds a **new dataset** — an empty, migrated database of its own — fills it
/// from the archive, and only then puts it in place. Nothing of the live library is
/// touched until that has all worked, and the library it replaced is kept aside as a file
/// (`LocalBackups`), so "that was the wrong archive" is one button, not a lost evening.
/// The dangerous direction is a bad local state overwriting a good copy somewhere else,
/// and this is the tier that makes undoing it possible without reaching for one.
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

    /// Restores `archive` into a dataset of its own and switches to it. Returns what
    /// landed and what's waiting on a sync, same as a merge-in-place would.
    @discardableResult
    static func restore(_ archive: Data) throws -> BackupImportResult {
        let live = BackupService()
        let snapshot = try live.unarchive(archive)

        // Both copies of what's about to be replaced: the zip for anywhere, the database
        // file for here — a swap back, with no matching or re-linking in between.
        if let current = try? live.currentArchive() {
            LocalBackups.writeBefore("restore", archive: current)
        }
        let preservedName = (BackupArchiveName.beforeOperation("restore") as NSString).deletingPathExtension + ".sqlite"
        let preserved = LocalBackups.copyDatabase(named: preservedName)

        let stagingURL = URL.applicationSupportDirectory.appending(path: "restoring.sqlite")
        remove(stagingURL)
        defer { remove(stagingURL) }
        let staged = try DatabaseManager.makeDataset(at: stagingURL)
        let result = try BackupService(dbQueue: staged).apply(snapshot)

        try DatabaseManager.shared.replaceContents(with: staged)
        if let preserved {
            UserDefaults.standard.set(preserved.lastPathComponent, forKey: previousKey)
            UserDefaults.standard.set(Date(), forKey: previousAtKey)
        }
        // Everything in the new dataset is waiting on a sync — it holds what the archive
        // held and nothing else, so no episode file is matched yet.
        if result.awaitingSync > 0 { PendingRestore.save(archive) } else { PendingRestore.clear() }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
