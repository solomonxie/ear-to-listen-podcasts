import Foundation

/// What a backup archive is called, wherever it's kept: one file per day,
/// `20260918-ear-to-listen.zip`, rewritten by every run that day and left alone after it.
///
/// A day is the unit because that's the cadence every off-device copy runs at, so the
/// name says exactly which run wrote it and nothing is ever overwritten by a later day's
/// mistake. What keeps that from becoming a scrolling pile is retention, not naming:
/// iCloud keeps the latest ten and prunes the rest, the bucket keeps every one of them
/// forever, and the copies in Files age out after a week (`LocalBackups`).
///
/// The name is also the sort order, which is why the date comes first and is zero-padded:
/// picking the newest archive is `max()` over the names, with no dates to parse and no
/// listing metadata to trust. Monthly names from earlier builds still sort and still
/// restore — they rank as the first of their month, so any day's copy beats them.
enum BackupArchiveName {
    /// Says which app left the file behind. Spelled out rather than abbreviated: this sits
    /// in an iCloud folder and an S3 bucket the listener browses years later.
    static let suffix = "ear-to-listen"

    /// What the app was called before, still read so every copy it ever wrote restores.
    /// Write the new name, read both — a rename that strands the backups is a rename that
    /// loses the library.
    static let legacySuffixes = ["byopo"]

    private static var suffixes: [String] { [suffix] + legacySuffixes }

    static func current(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        base(date, calendar: calendar) + ".zip"
    }

    /// Without the extension, for `fileExporter` — which appends its own.
    static func base(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d-%@", day.year ?? 0, day.month ?? 0, day.day ?? 0, suffix)
    }

    /// The extra copy a large operation writes before it runs — an import, a restore,
    /// anything that rewrites many rows at once. A name of its own, so the day's rolling
    /// copy can't overwrite it and the listener can tell at a glance what it precedes.
    static func beforeOperation(_ operation: String, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let stamp = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%@-before-%@-%04d%02d%02d-%02d%02d%02d.zip", suffix, operation,
            stamp.year ?? 0, stamp.month ?? 0, stamp.day ?? 0,
            stamp.hour ?? 0, stamp.minute ?? 0, stamp.second ?? 0
        )
    }

    /// The copy made immediately before erasing this installation. It deliberately does
    /// not look like a daily archive, so a later backup of the empty library cannot
    /// replace it.
    static func beforeRemovingAllData(at date: Date = Date(), calendar: Calendar = .current) -> String {
        beforeOperation("remove-all-data", at: date, calendar: calendar)
    }

    static func matches(_ name: String) -> Bool {
        rank(of: name) != nil
    }

    /// The newest archive among some file names — the one to restore from. Names that
    /// aren't dated archives (including the single-file backups older builds wrote, and
    /// the copies a large operation leaves behind) are left to the caller's own fallback.
    static func newest<Names: Sequence<String>>(among names: Names) -> String? {
        let names = Array(names)
        if let recovery = names.filter(isBeforeRemovingAllData).max() { return recovery }
        return names.filter(matches).max { left, right in rank(of: left)! < rank(of: right)! }
    }

    /// Oldest first, for a destination that keeps a fixed number of them.
    static func oldestFirst<Names: Sequence<String>>(among names: Names) -> [String] {
        names.filter(matches).sorted { rank(of: $0)! < rank(of: $1)! }
    }

    /// `20260918` out of `20260918-ear-to-listen.zip`, and `202609` — a month from an older build —
    /// padded to `20260900` so a day in that month always outranks it.
    private static func rank(of name: String) -> String? {
        let fileName = name.split(separator: "/").last.map(String.init) ?? name
        guard let matched = suffixes.first(where: { fileName.hasSuffix("-\($0).zip") }) else { return nil }
        let stamp = fileName.dropLast("-\(matched).zip".count)
        guard stamp.allSatisfy(\.isNumber) else { return nil }
        switch stamp.count {
        case 8: return String(stamp)
        case 6: return stamp + "00"
        default: return nil
        }
    }

    private static func isBeforeRemovingAllData(_ name: String) -> Bool {
        name.split(separator: "/").last.map(String.init)?.contains("-before-remove-all-data-") ?? false
    }
}
