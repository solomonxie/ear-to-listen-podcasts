import GRDB
import XCTest
@testable import EarToListen

/// The tier that stays on the phone: what it keeps, what it drops, and what it refuses to
/// write down.
final class LocalBackupsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, daysAgo: Double) throws {
        let url = directory.appending(path: name)
        try Data("x".utf8).write(to: url)
        let modifiedAt = Date().addingTimeInterval(-daysAgo * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func remaining() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// Age, not count: a week of copies stays a week of copies however many imports were
    /// made in it, where a count would quietly spend yesterday's on today's third import.
    func testKeepsAWeekOfCopiesAndDropsWhatIsOlder() throws {
        try write("20260918-ear-to-listen.zip", daysAgo: 0)
        try write("20260912-ear-to-listen.zip", daysAgo: 6)
        try write("20260901-ear-to-listen.zip", daysAgo: 17)
        try write("20260918-ear-to-listen.sqlite", daysAgo: 1)
        try write("20260901-ear-to-listen.sqlite", daysAgo: 30)
        try write("20260910.jsonl", daysAgo: 8)

        LocalBackups.prune(in: [directory])

        XCTAssertEqual(try remaining(), ["20260918-ear-to-listen.zip", "20260912-ear-to-listen.zip", "20260918-ear-to-listen.sqlite"])
    }

    /// A copy taken before a large operation ages out like everything else — but it is
    /// never the day's rolling file, so that day's run can't overwrite it in the meantime.
    func testTheCopyBeforeALargeOperationAgesOutTooButIsNeverOverwritten() throws {
        try write("ear-to-listen-before-import-20260918-140233.zip", daysAgo: 0)
        try write("ear-to-listen-before-import-20260901-090000.zip", daysAgo: 17)

        LocalBackups.prune(in: [directory])

        XCTAssertEqual(try remaining(), ["ear-to-listen-before-import-20260918-140233.zip"])
    }

    /// The folder opens in Files, so anything else in it belongs to the listener.
    func testLeavesFilesItDidNotWriteAlone() throws {
        try write("notes.zip", daysAgo: 400)
        try write("Episode.mp3", daysAgo: 400)

        LocalBackups.prune(in: [directory])

        XCTAssertEqual(try remaining(), ["notes.zip", "Episode.mp3"])
    }

    /// A restore fills a database of its own before anything of the live one is touched,
    /// and those writes are not the listener's history — nor are a test's.
    func testTheChangeLogIgnoresADatabaseThatIsNotTheLiveOne() throws {
        let dbQueue = try DatabaseQueue()
        try Migrations.migrator().migrate(dbQueue)
        let mark = ChangeLog.mark

        try PlaylistStore(dbQueue: dbQueue).create(
            Playlist(id: "pl1", name: "Favorites", source: "local", createdAt: Date())
        )
        try PlaylistStore(dbQueue: dbQueue).rename(id: "pl1", to: "Night listening")
        try PlaylistStore(dbQueue: dbQueue).delete(id: "pl1")

        XCTAssertEqual(ChangeLog.mark, mark)
    }
}
