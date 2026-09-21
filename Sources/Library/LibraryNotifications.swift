import Foundation

extension Notification.Name {
    /// Posted after the library's real DB content changes in a way that isn't already
    /// covered by a targeted refresh — from `SyncEngine.importFileIfNeeded`, each
    /// newly-synced file — so Home's shelves (including newly-appearing speakers) update
    /// live instead of waiting for the next full view reload.
    static let libraryDidChange = Notification.Name("libraryDidChange")

    /// Posted whenever a bookmark is added or removed. Bookmarks show in four places at
    /// once — the player's button, Now Playing's list, the album page and Home — and none
    /// of them owns the others.
    static let bookmarksDidChange = Notification.Name("bookmarksDidChange")

    /// Posted once by `SyncEngine.sync(providerRecord:)` when a listing pass has queued
    /// its files. It's the wake-up as well as the refresh: `SyncQueueManager` both
    /// republishes its state and starts draining on it, so a pass running off the main
    /// actor doesn't need to know whether the loop is already alive.
    static let syncQueueDidChange = Notification.Name("syncQueueDidChange")
}
