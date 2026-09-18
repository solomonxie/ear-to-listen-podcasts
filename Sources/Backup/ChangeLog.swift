import Foundation
import GRDB

/// Every hand-made change to the data a backup carries, one line per row written, old
/// value beside new, appended and never rewritten.
///
/// This is what makes a once-a-day backup safe: a snapshot taken this morning plus the
/// log is a record of everything since, so nothing between copies is unrecoverable.
/// Local only — it names row ids that are regenerated on the next install, so it is never
/// replayed on restore. It still travels inside the archive (`BackupService.archive`) so
/// the record outlives the phone, and `LocalBackups` prunes it on the same seven-day age
/// rule as every other tier-1 file.
///
/// Only the tables a backup carries are logged. Synced track and library rows are left
/// out on purpose: a sync rebuilds them from the files themselves, so logging them would
/// bury the handful of entries anyone would ever want to read under a library re-scan.
enum ChangeLog {
    static let directory = URL.applicationSupportDirectory.appending(path: "change-log", directoryHint: .isDirectory)

    /// Counts entries ever written, so it only ever goes up — the off-device tiers compare
    /// it against the mark they last shipped to decide whether a day's upload is owed.
    /// A byte count would do the same until a prune deleted a file and it went backwards.
    private static let markKey = "backup.changeLog.mark"
    private static let writes = DispatchQueue(label: "com.solomonxie.eartolisten.changelog")

    struct Entry: Codable {
        var at: Date
        var table: String
        var key: String
        var old: String?
        var new: String?
    }

    static var mark: Int { UserDefaults.standard.integer(forKey: markKey) }

    /// Logs one row write. `dbQueue` decides whether it's logged at all: writes to a
    /// restore's half-built dataset, a test's in-memory database or anything else that
    /// isn't the live library have nothing to do with the listener's own history.
    static func record(
        _ table: String, key: String, old: (any Encodable)? = nil, new: (any Encodable)? = nil,
        in dbQueue: DatabaseQueue
    ) {
        guard dbQueue.path == DatabaseManager.databaseURL.path else { return }
        let entry = Entry(at: Date(), table: table, key: key, old: json(old), new: json(new))
        UserDefaults.standard.set(mark + 1, forKey: markKey)
        writes.async { append(entry) }
    }

    /// The log as it stands, newest file last, for the caller that ships it somewhere.
    static func files() -> [URL] {
        let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return listed.filter { $0.hasSuffix(".jsonl") }.sorted().map { directory.appending(path: $0) }
    }

    private static func append(_ entry: Entry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName(for: entry.at))
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// One file per day, named so it sorts by date and prunes by reading its own name.
    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d.jsonl", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    private static func json(_ value: (any Encodable)?) -> String? {
        guard let value, let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
