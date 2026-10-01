import Foundation
import GRDB

/// Switches between the listener's library and the sample one, in place.
///
/// Entering copies the live database aside (`demo/real-library.sqlite`), builds the sample
/// library in a dataset of its own and swaps it in through the connection everything
/// already holds. Leaving swaps the copy back. The flag is set before the first swap and
/// cleared after the second, so a crash in between leaves a state that leaving again
/// repairs — never the sample library mistaken for the real one.
@MainActor
enum DemoMode {
    private static let directory = URL.applicationSupportDirectory.appending(path: "demo", directoryHint: .isDirectory)
    private static let stashURL = directory.appending(path: "real-library.sqlite")
    private static let stagingURL = directory.appending(path: "staging.sqlite")
    /// The real library as it was last put back — kept until the next switch, in case.
    private static let previousURL = directory.appending(path: "real-library.previous.sqlite")

    static var isOn: Bool { AppMode.isDemo }

    static func enter() throws {
        guard !isOn else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        quiesce()
        defer { resume() }

        DatabaseManager.shared.checkpoint()
        removeDatabase(at: stashURL)
        try DatabaseManager.shared.dbQueue.backup(to: DatabaseQueue(path: stashURL.path))
        try verify(stashURL, matches: DatabaseManager.shared.dbQueue)
        UserDefaults.standard.set(true, forKey: AppMode.demoKey)

        removeDatabase(at: stagingURL)
        defer { removeDatabase(at: stagingURL) }
        let staged = try DatabaseManager.makeDataset(at: stagingURL)
        try DemoDataSeeder.seed(into: staged)
        DemoSecrets.apply(to: staged)
        try DatabaseManager.shared.replaceContents(with: staged)
    }

    static func leave() throws {
        guard isOn else { return }
        quiesce()
        defer { resume() }
        DemoSecrets.forget(in: DatabaseManager.shared.dbQueue)

        if let saved = [stashURL, previousURL].first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let copy = try DatabaseQueue(path: saved.path)
            try verify(saved, matches: nil)
            try DatabaseManager.shared.replaceContents(with: copy)
        } else {
            removeDatabase(at: stagingURL)
            defer { removeDatabase(at: stagingURL) }
            try DatabaseManager.shared.replaceContents(with: DatabaseManager.makeDataset(at: stagingURL))
        }
        DatabaseManager.shared.purgeWriteAheadLog()
        UserDefaults.standard.set(false, forKey: AppMode.demoKey)
        if FileManager.default.fileExists(atPath: stashURL.path) {
            removeDatabase(at: previousURL)
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.moveItem(
                    at: URL(fileURLWithPath: stashURL.path + suffix),
                    to: URL(fileURLWithPath: previousURL.path + suffix)
                )
            }
        }
    }

    private static func quiesce() {
        PlaybackEngine.shared.unload()
        SyncScheduler.shared.stop()
    }

    private static func resume() {
        ProviderManager.shared.invalidateAll()
        SyncScheduler.shared.start()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Refuses a copy SQLite calls damaged, or one missing episodes the live library has —
    /// a swap with either would lose the real library.
    private static func verify(_ url: URL, matches live: DatabaseQueue?) throws {
        let copy = try DatabaseQueue(path: url.path)
        let (check, copied) = try copy.read { db in
            (try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "", try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0)
        }
        let expected = try live?.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0 }
        guard check == "ok", expected.map({ $0 == copied }) ?? true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private static func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
