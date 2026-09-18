import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    /// Where the live library sits. A static, so asking "is this the live database?" —
    /// which `ChangeLog` does on every write — doesn't open it.
    static let databaseURL = URL.applicationSupportDirectory.appending(path: "ear-to-listen.sqlite")

    /// What the file was called before the app was renamed. Moved into place on launch if
    /// it's still there, so an update in the same container keeps its library.
    private static let legacyDatabaseURL = URL.applicationSupportDirectory.appending(path: "byopo.sqlite")

    let dbQueue: DatabaseQueue

    private init() {
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        Self.adoptLegacyDatabase()
        dbQueue = try! DatabaseQueue(path: Self.databaseURL.path)
        try! Migrations.migrator().migrate(dbQueue)
    }

    /// Takes over the database the app wrote under its old name, sidecars included — a
    /// rename is not a reason to start with an empty library.
    private static func adoptLegacyDatabase() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: databaseURL.path),
              manager.fileExists(atPath: legacyDatabaseURL.path)
        else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? manager.moveItem(
                at: URL(fileURLWithPath: legacyDatabaseURL.path + suffix),
                to: URL(fileURLWithPath: databaseURL.path + suffix)
            )
        }
    }

    /// A migrated, empty database at `url` — what a restore fills before anything of the
    /// live one is touched.
    static func makeDataset(at url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: url.path)
        try Migrations.migrator().migrate(dbQueue)
        return dbQueue
    }

    /// Flushes anything sitting in the write-ahead sidecar into the database file, so a
    /// plain file copy of it isn't missing the newest writes.
    func checkpoint() {
        try? dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(FULL)")
        }
    }

    /// Replaces the live library's contents with `source`, through the connection every
    /// part of the app is already holding — so a restore doesn't leave a `SyncEngine` or
    /// a player reading a database nobody writes to any more.
    func replaceContents(with source: DatabaseQueue) throws {
        try source.backup(to: dbQueue)
    }
}
