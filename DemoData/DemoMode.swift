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

    static var isOn: Bool { AppMode.isDemo }

    static func enter() throws {
        guard !isOn else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        quiesce()

        DatabaseManager.shared.checkpoint()
        removeDatabase(at: stashURL)
        try DatabaseManager.shared.dbQueue.backup(to: DatabaseQueue(path: stashURL.path))
        UserDefaults.standard.set(true, forKey: AppMode.demoKey)

        removeDatabase(at: stagingURL)
        defer { removeDatabase(at: stagingURL) }
        let staged = try DatabaseManager.makeDataset(at: stagingURL)
        try DemoDataSeeder.seed(into: staged)
        DemoSecrets.apply(to: staged)
        try DatabaseManager.shared.replaceContents(with: staged)
        resume()
    }

    static func leave() throws {
        guard isOn else { return }
        quiesce()
        DemoSecrets.forget(in: DatabaseManager.shared.dbQueue)

        if FileManager.default.fileExists(atPath: stashURL.path) {
            try DatabaseManager.shared.replaceContents(with: DatabaseQueue(path: stashURL.path))
        } else {
            removeDatabase(at: stagingURL)
            defer { removeDatabase(at: stagingURL) }
            try DatabaseManager.shared.replaceContents(with: DatabaseManager.makeDataset(at: stagingURL))
        }
        DatabaseManager.shared.purgeWriteAheadLog()
        UserDefaults.standard.set(false, forKey: AppMode.demoKey)
        removeDatabase(at: stashURL)
        resume()
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

    private static func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
