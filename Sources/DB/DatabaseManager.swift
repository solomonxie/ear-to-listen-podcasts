import Foundation
import GRDB

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    private init() {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dbURL = directory.appending(path: "byopo.sqlite")
        dbQueue = try! DatabaseQueue(path: dbURL.path)
        try! Migrations.migrator().migrate(dbQueue)
    }
}
