import Foundation

extension YouTubeEpisodes {
    /// Links shared in from another app while this one was away. Title and channel come
    /// from YouTube; a link whose details can't be read waits for the next open rather
    /// than becoming an episode called nothing.
    static func addShared() async {
        var retry: [String] = []
        for link in ShareInbox.takeAll() {
            guard let videoID = YouTubeVideo.id(from: link), existing(videoID) == nil else { continue }
            guard let info = try? await YouTubeVideo.info(id: videoID) else {
                retry.append(link)
                continue
            }
            if (try? await add(videoID, title: info.title, speaker: info.channel)) == nil { retry.append(link) }
        }
        retry.forEach(ShareInbox.add)
    }
}
