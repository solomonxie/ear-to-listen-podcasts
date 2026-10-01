import Foundation

/// The copies that never leave the phone — the tier that answers a different failure from
/// iCloud and the bucket. Those two are for a phone that's gone; this one is for data
/// that's still here and now wrong: a bad import, a restore of the wrong archive, an edit
/// nobody meant. It's the only copy that's instant, offline, and there the moment it's
/// wanted.
///
/// Three things. The two copies age out after a week; the change log never does:
///
/// - **Database copies** (`snapshots/`) — the file itself, not a zip, so putting one back
///   is a file swap, and the only copy that survives a schema going wrong, which no
///   row-level undo can fix. The write-ahead sidecar is checkpointed first or the copy is
///   missing the newest writes.
/// - **The change log** (`ChangeLog`) — what fills the gap between one day's copy and the
///   next, and the only record that reaches back past the week of copies. Kept for the
///   life of the install, so every archive written carries the history from day one.
/// - **Archive zips**, in the Documents folder the listener can open in Files. The same
///   bytes every other tier gets, so one can be dragged out to anywhere.
///
/// The copies are pruned by age rather than by count: once a large operation can add files
/// of its own, a count silently decides how many imports it takes to lose yesterday.
/// "Anything from the last week" is a promise that stays true. It is never offered as a
/// backup *destination* — it shares the app's sandbox, so deleting the app takes it and
/// the library together.
enum LocalBackups {
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Files, not Application Support, so `UIFileSharingEnabled` puts them where the
    /// listener can reach them. The door is the whole point of this tier.
    static var archivesDirectory: URL { URL.documentsDirectory }
    static var snapshotsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "snapshots", directoryHint: .isDirectory)
    }

    private static let lastRunKey = "backup.local.lastAt"
    private static let lastMarkKey = "backup.local.mark"

    /// The whole tier-1 pass, on app-background. At most once a day and only if something
    /// was written since the last one: copying megabytes per keystroke to guard against a
    /// once-a-year event is the wrong trade, and the log already covers what falls between.
    static func runIfDue(archive: () throws -> Data) {
        guard !AppMode.isDemo else { return }
        let defaults = UserDefaults.standard
        let lastAt = defaults.object(forKey: lastRunKey) as? Date
        guard ChangeLog.mark != defaults.integer(forKey: lastMarkKey) else { return }
        guard lastAt.map({ !Calendar.current.isDateInToday($0) }) ?? true else { return }

        if let archive = try? archive() {
            write(archive, named: BackupArchiveName.current())
        }
        copyDatabase(named: BackupArchiveName.base() + ".sqlite")
        prune()
        defaults.set(Date(), forKey: lastRunKey)
        defaults.set(ChangeLog.mark, forKey: lastMarkKey)
    }

    /// The copy taken before something rewrites many rows at once — an import, a restore.
    /// This is the one that actually gets used: a bad import is the failure people hit, and
    /// it lands minutes after the day's rolling copy caught the good state, or hours after,
    /// having caught nothing.
    @discardableResult
    static func writeBefore(_ operation: String, archive: Data) -> URL? {
        write(archive, named: BackupArchiveName.beforeOperation(operation))
    }

    @discardableResult
    static func writePreDeletion(_ archive: Data, named name: String) -> URL? {
        write(archive, named: name)
    }

    /// The live database file, kept aside under its own name — how a restore is undone.
    @discardableResult
    static func copyDatabase(named name: String) -> URL? {
        DatabaseManager.shared.checkpoint()
        let destination = snapshotsDirectory.appending(path: name)
        try? FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: DatabaseManager.databaseURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Everything this tier holds that has aged out. Nothing else in these folders is
    /// touched: only files this wrote, matched by name.
    ///
    /// `ChangeLog.directory` is deliberately not in the list. The copies are worth ageing
    /// out — each one is the whole library again — but the log is a few hundred bytes a
    /// day and it is the only thing that says what happened before the oldest copy still
    /// here. Deleting it would leave the week of zips answering "what does it look like
    /// now" and nothing at all answering "what changed, and when".
    static var prunedDirectories: [URL] { [archivesDirectory, snapshotsDirectory] }

    static func prune(now: Date = Date(), in directories: [URL] = prunedDirectories) {
        for url in directories.flatMap(ours(in:)) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            guard let modifiedAt, now.timeIntervalSince(modifiedAt) > maximumAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func archives() -> [URL] {
        ours(in: archivesDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func databaseCopies() -> [URL] {
        ours(in: snapshotsDirectory).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    private static func write(_ archive: Data, named name: String) -> URL? {
        let url = archivesDirectory.appending(path: name)
        try? FileManager.default.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
        do {
            try archive.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func ours(in directory: URL) -> [URL] {
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return listed.filter(isOurs).map { directory.appending(path: $0) }
    }

    /// A dated archive or database copy this wrote, in either extension — and nothing else
    /// the listener may have dropped into the same folder. Change-log files are not a name
    /// this recognises: nothing here should be able to delete one by being pointed at the
    /// folder they live in.
    private static func isOurs(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        guard !name.hasSuffix(".jsonl") else { return false }
        return BackupArchiveName.ours(stem + ".zip")
    }
}
