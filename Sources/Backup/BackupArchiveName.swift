import Foundation

/// What a backup archive is called, wherever it's kept: one file per calendar month,
/// `202609-byopo.zip`, rewritten every run until the month turns over.
///
/// A single overwritten file has no history at all — a mistake noticed a week later has
/// already been backed up over — and a file per run turns a folder the listener opens in
/// Files into a scrolling pile of near-identical zips. A month is the middle: twelve
/// files a year, each obviously datable at a glance, and last month's copy still there
/// when this month's has eaten something.
///
/// The name is also the sort order, which is why the month comes first and is zero-padded:
/// picking the newest archive is `max()` over the names, with no dates to parse and no
/// listing metadata to trust.
enum BackupArchiveName {
    /// Says which app left the file behind. Spelled out rather than abbreviated: this sits
    /// in an iCloud folder and an S3 bucket the listener browses years later.
    static let suffix = "byopo"

    static func current(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        base(date, calendar: calendar) + ".zip"
    }

    /// Without the extension, for `fileExporter` — which appends its own.
    static func base(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let month = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d%02d-%@", month.year ?? 0, month.month ?? 0, suffix)
    }

    static func matches(_ name: String) -> Bool {
        month(of: name) != nil
    }

    /// The newest archive among some file names — the one to restore from. Names that
    /// aren't monthly archives (including the single-file backups older builds wrote) are
    /// left to the caller's own fallback.
    static func newest<Names: Sequence<String>>(among names: Names) -> String? {
        names.filter(matches).max { left, right in month(of: left)! < month(of: right)! }
    }

    /// `202609` out of `202609-byopo.zip`, and nothing out of anything else.
    private static func month(of name: String) -> String? {
        let fileName = name.split(separator: "/").last.map(String.init) ?? name
        guard fileName.hasSuffix("-\(suffix).zip") else { return nil }
        let month = fileName.dropLast("-\(suffix).zip".count)
        guard month.count == 6, month.allSatisfy(\.isNumber) else { return nil }
        return String(month)
    }
}
