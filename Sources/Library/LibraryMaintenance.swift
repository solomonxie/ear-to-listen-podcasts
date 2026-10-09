import Foundation

/// One-time housekeeping, off the main actor and after the first screen is up. Once per
/// install, not per launch: it reads the whole library inside a write, and Home's first
/// queries wait behind it.
enum LibraryMaintenance {
    private static let doneKey = "maintenance.foldedScannedDuplicates"

    private static let voiceTracksRemovedKey = "maintenance.removedVoiceTracks"

    @MainActor
    static func runOnce() {
        removeVoiceTracksOnce()
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)
        let dbQueue = DatabaseManager.shared.dbQueue
        let store = TrackStore(dbQueue: dbQueue)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            // Duplicates the fast scan made before it checked for the same recording, then
            // the "(2)" numbering they leave behind.
            let folded = (try? await dbQueue.write { db in try TrackMerge.foldAll(in: db) }) ?? 0
            let renamed = (try? store.numberDuplicateTitles()) ?? 0
            if folded + renamed > 0 {
                await MainActor.run { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
            }
        }
    }

    /// Spoken-transcript files from the voice-track feature, which is gone.
    @MainActor
    private static func removeVoiceTracksOnce() {
        guard !UserDefaults.standard.bool(forKey: voiceTracksRemovedKey) else { return }
        UserDefaults.standard.set(true, forKey: voiceTracksRemovedKey)
        let directory = URL.applicationSupportDirectory.appending(path: "voice", directoryHint: .isDirectory)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
    }
}
