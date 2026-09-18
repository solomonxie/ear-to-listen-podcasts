import XCTest
@testable import BringYourOwnPodcasts

final class BackupArchiveNameTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    func testNamesOneArchivePerMonth() {
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(BackupArchiveName.current(date(2026, 9, 1), calendar: calendar), "202609-byopo.zip")
        XCTAssertEqual(BackupArchiveName.current(date(2026, 9, 30), calendar: calendar), "202609-byopo.zip")
        XCTAssertEqual(BackupArchiveName.current(date(2026, 10, 1), calendar: calendar), "202610-byopo.zip")
        XCTAssertEqual(BackupArchiveName.base(date(2027, 1, 5), calendar: calendar), "202701-byopo")
    }

    func testPicksTheNewestMonth() {
        let names = ["202512-byopo.zip", "202601-byopo.zip", "202609-byopo.zip", "202602-byopo.zip"]
        XCTAssertEqual(BackupArchiveName.newest(among: names), "202609-byopo.zip")
        // A year boundary is why the month is zero-padded and sorts as text.
        XCTAssertEqual(BackupArchiveName.newest(among: ["202512-byopo.zip", "202601-byopo.zip"]), "202601-byopo.zip")
    }

    func testKeepsWholeKeysSoABucketListingCanBeHandedStraightIn() {
        let keys = ["podcasts/bring-your-own-podcasts/202608-byopo.zip", "podcasts/bring-your-own-podcasts/202609-byopo.zip"]
        XCTAssertEqual(BackupArchiveName.newest(among: keys), "podcasts/bring-your-own-podcasts/202609-byopo.zip")
    }

    /// Anything that isn't a monthly archive is left to the caller's own legacy fallback.
    func testIgnoresEverythingElse() {
        let names = [
            "byo-podcasts-backup.zip", "app-data-backup.zip", "202609-byopo.txt",
            "2026-byopo.zip", "20260a-byopo.zip", "202609-other.zip", "notes.zip",
        ]
        XCTAssertNil(BackupArchiveName.newest(among: names))
        XCTAssertFalse(names.contains(where: BackupArchiveName.matches))
        XCTAssertTrue(BackupArchiveName.matches("202609-byopo.zip"))
    }
}
