import Foundation

/// The row an episode belongs to once every bucket that ever held it is gone. Not a real
/// source — nothing syncs to it, lists it in Settings, or streams from it — just somewhere
/// for `tracks.providerID` to point so the listener's history and notes on that row survive
/// the provider row itself being deleted (see `ProviderStore.delete`'s cascade).
enum OrphanedEpisodes {
    static let providerID = "lost"
    static let providerType = "lost"

    /// A path that stays unique once parked here even though two different deleted
    /// buckets can otherwise name the same relative file — `idx_tracks_provider_path` is
    /// unique on (providerID, filePath), and every orphan shares this one providerID.
    /// Deterministic, so looking this back up from the original pair (a backup restoring
    /// the same episode a second time, say) finds the row that's already here instead of
    /// making a duplicate.
    static func path(originalProviderID: String, originalFilePath: String) -> String {
        "\(originalProviderID)/\(originalFilePath)"
    }
}
