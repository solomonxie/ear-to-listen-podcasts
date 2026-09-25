import Foundation

/// What a backup archive is called, wherever it's kept: **when, what for, whose** —
/// `20260918-daily-ear-to-listen.zip`, `20260918140233-pre-deletion-ear-to-listen.zip`.
///
/// When comes first because the name is also the sort order: picking the newest archive
/// is `max()` over the names, with no dates to parse and no listing metadata to trust —
/// which is why it's zero-padded and why the time, where there is one, runs straight on
/// from the day. What it's for comes next, so a folder listing read a year later says
/// which copy precedes what without opening any of them. The app's own name comes last:
/// it's the part that never varies, and it belongs where it can't push the two parts that
/// do out of line.
///
/// The daily copy is named to the day, not the second, because that *is* the cadence: one
/// file per day, rewritten by every run that day and left alone after it, so nothing is
/// ever overwritten by a later day's mistake. The copies taken before something
/// irreversible are named to the second, because two of those can land in one day and
/// each one matters. What keeps either from becoming a scrolling pile is retention, not
/// naming: iCloud keeps the latest ten, the bucket keeps every one of them forever, and
/// the copies in Files age out after a week (`LocalBackups`).
///
/// Every name this app has ever written is still read. Earlier builds put the app name
/// first (`ear-to-listen-pre-deletion-20260918-140233.zip`), wrote one file per month, and
/// called themselves `byopo` — and an archive that can't be recognised is a library
/// quietly passed over on the one day it's wanted.
enum BackupArchiveName {
    /// Says which app left the file behind. Spelled out rather than abbreviated: this sits
    /// in an iCloud folder and an S3 bucket the listener browses years later.
    static let suffix = "ear-to-listen"

    /// What the app was called before, still read so every copy it ever wrote restores.
    /// Write the new name, read both — a rename that strands the backups is a rename that
    /// loses the library.
    static let legacySuffixes = ["byopo"]

    /// The rolling copy: what a day's run is for, as against the copies taken before
    /// something that can't be undone.
    static let dailyMarker = "daily"

    /// The copy made immediately before erasing this installation. It deliberately does
    /// not look like a daily archive, so a later backup of the empty library cannot
    /// replace it, and it says what it precedes in a word anyone reading a folder listing
    /// a year later will understand.
    static let preDeletionMarker = "pre-deletion"

    private static var suffixes: [String] { [suffix] + legacySuffixes }

    static func current(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        base(date, calendar: calendar) + ".zip"
    }

    /// Without the extension, for `fileExporter` — which appends its own.
    static func base(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        "\(day(date, calendar: calendar))-\(dailyMarker)-\(suffix)"
    }

    /// The extra copy a large operation writes before it runs — an import, a restore,
    /// anything that rewrites many rows at once. Named to the second and by the operation
    /// it precedes, so the day's rolling copy can't overwrite it, two in one afternoon
    /// can't overwrite each other, and the listener can tell at a glance what it precedes.
    static func beforeOperation(_ operation: String, at date: Date = Date(), calendar: Calendar = .current) -> String {
        "\(second(date, calendar: calendar))-before-\(operation)-\(suffix).zip"
    }

    static func preDeletion(at date: Date = Date(), calendar: Calendar = .current) -> String {
        "\(second(date, calendar: calendar))-\(preDeletionMarker)-\(suffix).zip"
    }

    private static func day(_ date: Date, calendar: Calendar) -> String {
        let at = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", at.year ?? 0, at.month ?? 0, at.day ?? 0)
    }

    private static func second(_ date: Date, calendar: Calendar) -> String {
        let at = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return day(date, calendar: calendar) + String(format: "%02d%02d%02d", at.hour ?? 0, at.minute ?? 0, at.second ?? 0)
    }

    static func matches(_ name: String) -> Bool {
        rank(of: name) != nil
    }

    /// A file this app wrote, under any of the names it has used — so a prune only ever
    /// takes its own, and nothing the listener dropped in the same folder.
    static func ours(_ name: String) -> Bool {
        let fileName = fileName(of: name)
        // The old spelling led with the app name; the current one ends with it.
        if suffixes.contains(where: { fileName.hasPrefix("\($0)-") }) { return true }
        guard let stem = stem(of: fileName) else { return false }
        return stem.split(separator: "-").first?.allSatisfy(\.isNumber) ?? false
    }

    /// The newest archive among some file names — the one to restore from. Names that
    /// aren't dated archives (including the single-file backups older builds wrote, and
    /// the copies a large operation leaves behind) are left to the caller's own fallback.
    static func newest<Names: Sequence<String>>(among names: Names) -> String? {
        preferred(among: names).first
    }

    /// Every archive worth trying, best first: the pre-deletion copies, then the dated
    /// ones, newest of each first. A restore walks the whole list rather than taking the
    /// top name, so one copy that turns out to hold nothing — the archive a wipe of an
    /// already-empty library used to leave behind — can't hide the good ones under it.
    static func preferred<Names: Sequence<String>>(among names: Names) -> [String] {
        let names = Array(names)
        return names.filter(isPreDeletion).sorted { stamp(of: $0) > stamp(of: $1) }
            + names.filter(matches).sorted { rank(of: $0)! > rank(of: $1)! }
    }

    /// Oldest first, for a destination that keeps a fixed number of them.
    static func oldestFirst<Names: Sequence<String>>(among names: Names) -> [String] {
        names.filter(matches).sorted { rank(of: $0)! < rank(of: $1)! }
    }

    /// `20260918000000` out of `20260918-daily-ear-to-listen.zip`, and `202609` — a month
    /// from an older build — padded to `20260900000000` so any day in that month outranks
    /// it. Everything is padded to the same width, so a day and a day-and-time compare as
    /// text without either being parsed.
    private static func rank(of name: String) -> String? {
        guard let stem = stem(of: fileName(of: name)) else { return nil }
        let parts = stem.split(separator: "-")
        guard let stamp = parts.first, stamp.allSatisfy(\.isNumber) else { return nil }
        // A copy taken before something, not a dated archive: the caller's own fallback.
        guard !parts.dropFirst().contains(where: { $0 == "before" }), !stem.contains(preDeletionMarker) else { return nil }
        switch stamp.count {
        case 14: return String(stamp)
        case 8: return stamp + "000000"
        case 6: return stamp + "00000000"
        default: return nil
        }
    }

    /// Both spellings: earlier builds led with the app name and named this copy after the
    /// button that made it (`-before-remove-all-data-`), and an archive that can't be
    /// recognised is an archive a reinstall silently passes over.
    private static func isPreDeletion(_ name: String) -> Bool {
        let fileName = fileName(of: name)
        return fileName.contains("-\(preDeletionMarker)-") || fileName.contains("-before-remove-all-data-")
    }

    /// Whatever digits the name leads with, or trails with in the old spelling — enough to
    /// sort two copies taken on the same day by the second that separates them.
    private static func stamp(of name: String) -> String {
        fileName(of: name).split(separator: "-").filter { $0.allSatisfy(\.isNumber) }.joined()
    }

    /// The name without the app it belongs to, or nil if it doesn't belong to this one.
    private static func stem(of fileName: String) -> String? {
        guard let matched = suffixes.first(where: { fileName.hasSuffix("-\($0).zip") }) else { return nil }
        return String(fileName.dropLast("-\(matched).zip".count))
    }

    private static func fileName(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
