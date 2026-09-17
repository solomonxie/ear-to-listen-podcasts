import Foundation

/// The two rules the sync queue runs under, kept somewhere anything can read them: the
/// drain loop is main-actor, whole-bucket sync passes aren't, and both have to honour the
/// same pause and the same ceiling.
enum SyncQueuePolicy {
    /// Most unfinished (pending + running) jobs the queue will hold. A bucket with
    /// thousands of files otherwise queues every one of them the moment it's added — hours
    /// of work nobody asked for, in a list nobody can read. Nothing is lost by stopping:
    /// the next sync picks up from wherever this one had to stop.
    static let capacity = 100

    private static let pausedKey = "syncQueue.isPaused"

    /// Paused stops both halves — nothing new is accepted, nothing waiting is started.
    /// Stored rather than held in memory, so a queue paused on purpose doesn't quietly
    /// resume itself on the next launch.
    static var isPaused: Bool {
        get { UserDefaults.standard.bool(forKey: pausedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pausedKey) }
    }

    struct PausedError: Error, LocalizedError {
        var errorDescription: String? { "The sync queue is paused. Resume it to sync." }
    }

    struct FullError: Error, LocalizedError {
        var errorDescription: String? {
            "The sync queue is full (\(SyncQueuePolicy.capacity) files waiting). Let it drain, then sync again to carry on where it stopped."
        }
    }
}
