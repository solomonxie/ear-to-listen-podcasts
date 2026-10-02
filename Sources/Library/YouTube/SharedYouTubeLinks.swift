import Foundation

extension YouTubeEpisodes {
    /// Links shared in from another app while this one was away. Title and channel come
    /// from YouTube; a link whose details can't be read waits for the next open rather
    /// than becoming an episode called nothing. Returns the last one shared — new, or
    /// already in the library and moved back to the top of the history.
    @discardableResult
    static func addShared() async -> Track? {
        var retry: [String] = []
        var latest: Track?
        for link in ShareInbox.takeAll() {
            guard let videoID = YouTubeVideo.id(from: link) else { continue }
            if let known = existing(videoID) {
                try? TrackStore(dbQueue: DatabaseManager.shared.dbQueue).touchLastPlayed(id: known.id)
                latest = known
                continue
            }
            guard let info = try? await YouTubeVideo.info(id: videoID),
                  let added = try? await add(videoID, title: info.title, speaker: info.channel) else {
                retry.append(link)
                continue
            }
            latest = added
        }
        retry.forEach(ShareInbox.add)
        if latest != nil { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
        return latest
    }

    /// Coming back from sharing a video: it's what you came to see, so its page opens —
    /// unless something is playing, which a share mustn't cut off.
    static func openShared() async {
        guard let track = await addShared() else { return }
        let engine = PlaybackEngine.shared
        guard !engine.isPlaying else { return }
        engine.open(track: track, queue: [track])
    }
}
