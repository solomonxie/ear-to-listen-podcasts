import UIKit

/// Marking the second that's playing, from wherever the bar making the mark happens to be
/// standing — the player, a page pushed off it, or Home. The mark is the same mark in all
/// three: same dedupe, same haptic, same spoken line saved beside it.
@MainActor
enum MomentMark {
    private static var store: BookmarkStore { BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue) }

    /// The line being spoken travels with the mark: what was said there is the reason it
    /// was marked, and a re-transcribe shouldn't be able to rewrite that.
    @discardableResult
    static func add(to track: Track, at time: Double) -> Bookmark? {
        let spoken = TranscriptRunner.shared.currentLine(at: time)?.text
        guard let saved = try? store.add(
            trackID: track.id, positionMs: Int(time * 1000), transcriptText: spoken
        ) else { return nil }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        return saved
    }

    static func count(forTrack trackID: String) -> Int {
        ((try? store.all(forTrack: trackID)) ?? []).count
    }
}
