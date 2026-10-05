import Foundation

/// Housekeeping run once per launch, off the main actor, after the first screen is up.
enum LibraryMaintenance {
    @MainActor private static var didRun = false

    @MainActor
    static func runOnce() {
        guard !didRun else { return }
        didRun = true
        let dbQueue = DatabaseManager.shared.dbQueue
        let store = TrackStore(dbQueue: dbQueue)
        Task.detached(priority: .utility) {
            // Duplicates the fast scan made before it checked for the same recording, then
            // the "(2)" numbering they leave behind.
            let folded = (try? await dbQueue.write { db in try TrackMerge.foldAll(in: db) }) ?? 0
            let renamed = (try? store.numberDuplicateTitles()) ?? 0
            if folded + renamed > 0 {
                await MainActor.run { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
            }
        }
    }
}
