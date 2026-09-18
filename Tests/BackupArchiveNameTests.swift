import XCTest
@testable import EarToListen

final class BackupArchiveNameTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)!
    }

    func testNamesOneArchivePerDay() {
        XCTAssertEqual(BackupArchiveName.current(date(2026, 9, 18), calendar: calendar), "20260918-ear-to-listen.zip")
        XCTAssertEqual(BackupArchiveName.current(date(2026, 10, 1), calendar: calendar), "20261001-ear-to-listen.zip")
        XCTAssertEqual(BackupArchiveName.base(date(2027, 1, 5), calendar: calendar), "20270105-ear-to-listen")
    }

    func testPicksTheNewestDay() {
        let names = ["20260917-ear-to-listen.zip", "20260918-ear-to-listen.zip", "20260901-ear-to-listen.zip"]
        XCTAssertEqual(BackupArchiveName.newest(among: names), "20260918-ear-to-listen.zip")
        // A year boundary is why the date is zero-padded and sorts as text.
        XCTAssertEqual(BackupArchiveName.newest(among: ["20251231-ear-to-listen.zip", "20260101-ear-to-listen.zip"]), "20260101-ear-to-listen.zip")
    }

    /// Builds before daily archives wrote one file per month. Those still restore, and a
    /// day from that month always outranks the month itself.
    func testMonthlyNamesFromOlderBuildsStillSort() {
        XCTAssertTrue(BackupArchiveName.matches("202609-ear-to-listen.zip"))
        XCTAssertEqual(BackupArchiveName.newest(among: ["202609-ear-to-listen.zip", "20260901-ear-to-listen.zip"]), "20260901-ear-to-listen.zip")
        XCTAssertEqual(BackupArchiveName.newest(among: ["202609-ear-to-listen.zip", "202608-ear-to-listen.zip"]), "202609-ear-to-listen.zip")
    }

    /// Copies taken under the app's old name still restore — a rename that strands the
    /// backups is a rename that loses the library.
    func testArchivesWrittenUnderTheOldNameStillRestore() {
        XCTAssertTrue(BackupArchiveName.matches("20260917-byopo.zip"))
        XCTAssertTrue(BackupArchiveName.matches("202608-byopo.zip"))
        XCTAssertEqual(
            BackupArchiveName.newest(among: ["20260917-byopo.zip", "20260918-ear-to-listen.zip"]),
            "20260918-ear-to-listen.zip"
        )
        // The old bucket folder is listed beside the new one, so the newest of the two wins.
        XCTAssertEqual(
            BackupArchiveName.newest(among: [
                "bring-your-own-podcasts/20260918-byopo.zip",
                "ear-to-listen-podcasts/20260917-ear-to-listen.zip",
            ]),
            "bring-your-own-podcasts/20260918-byopo.zip"
        )
    }

    /// What a destination that keeps a fixed number deletes first.
    func testOldestFirstForADestinationThatKeepsACount() {
        let names = ["20260918-ear-to-listen.zip", "202512-ear-to-listen.zip", "20260101-ear-to-listen.zip"]
        XCTAssertEqual(
            BackupArchiveName.oldestFirst(among: names),
            ["202512-ear-to-listen.zip", "20260101-ear-to-listen.zip", "20260918-ear-to-listen.zip"]
        )
    }

    func testKeepsWholeKeysSoABucketListingCanBeHandedStraightIn() {
        let keys = ["podcasts/ear-to-listen-podcasts/20260917-ear-to-listen.zip", "podcasts/ear-to-listen-podcasts/20260918-ear-to-listen.zip"]
        XCTAssertEqual(BackupArchiveName.newest(among: keys), "podcasts/ear-to-listen-podcasts/20260918-ear-to-listen.zip")
    }

    /// The copy a large operation leaves behind is named apart from the daily one, so the
    /// day's run can't overwrite it and "newest archive" never picks it.
    func testALargeOperationsCopyIsNamedApart() {
        let name = BackupArchiveName.beforeOperation("import", at: date(2026, 9, 18, 14, 2, 33), calendar: calendar)
        XCTAssertEqual(name, "ear-to-listen-before-import-20260918-140233.zip")
        XCTAssertFalse(BackupArchiveName.matches(name))
        XCTAssertNil(BackupArchiveName.newest(among: [name]))
    }

    func testIgnoresEverythingElse() {
        let names = [
            "byo-podcasts-backup.zip", "app-data-backup.zip", "20260918-ear-to-listen.txt",
            "2026-ear-to-listen.zip", "2026091a-ear-to-listen.zip", "20260918-other.zip", "notes.zip",
        ]
        XCTAssertNil(BackupArchiveName.newest(among: names))
        XCTAssertFalse(names.contains(where: BackupArchiveName.matches))
    }
}
