import GRDB
import XCTest
@testable import EarToListen

/// Upgrades from a schema that already holds episodes — migrations that decode today's
/// models crash here and nowhere else.
final class MigrationUpgradeTests: XCTestCase {
    func testAV30LibraryWithEpisodesUpgradesToTheLatestSchema() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = Migrations.migrator()
        try migrator.migrate(dbQueue, upTo: "v30_episode_summary_and_terms")
        try dbQueue.write { db in
            try insert(into: "providers", ["id": "p1", "type": "s3"], db)
            try insert(into: "tracks", ["id": "t1", "providerID": "p1", "filePath": "a.mp3", "title": "Encore (2)",
                                        "sizeBytes": 1000, "durationMs": 61_000], db)
            try insert(into: "tracks", ["id": "t2", "providerID": "p1", "filePath": "b/a.mp3", "title": "Encore",
                                        "sizeBytes": 1000, "durationMs": 61_400], db)
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT numberedFrom FROM tracks WHERE id = 't1'"), "Encore")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT fingerprint FROM tracks WHERE id = 't1'"), "1000-61")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackFiles"), 2)
            XCTAssertEqual(try TrackFile.fetchAll(db).map(\.filePath).sorted(), ["a.mp3", "b/a.mp3"])
            XCTAssertEqual(try Track.fetchCount(db), 2)
        }
    }

    /// Fills every NOT NULL column without a default, so the test doesn't pin the v30 schema.
    private func insert(into table: String, _ values: [String: (any DatabaseValueConvertible)?], _ db: Database) throws {
        var row = values
        for column in try db.columns(in: table) where column.isNotNull && column.defaultValueSQL == nil && row[column.name] == nil {
            switch column.type.uppercased() {
            case "INTEGER", "BOOLEAN": row[column.name] = 0
            case "DATETIME": row[column.name] = Date()
            default: row[column.name] = ""
            }
        }
        let names = Array(row.keys)
        try db.execute(
            sql: "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))",
            arguments: StatementArguments(names.map { row[$0]! })
        )
    }
}
