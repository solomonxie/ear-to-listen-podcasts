import Foundation

/// What the car's lists are built from. Every list is one query, read off the main actor,
/// so nothing here touches the database once per row.
struct CarLibrary: Sendable {
    struct Snapshot: Sendable {
        var continueListening: [Track] = []
        var listenLater: [Track] = []
        var favorites: [Track] = []
        var downloaded: [Track] = []
        var playlists: [Playlist] = []
        var collections: [Album] = []
        var speakers: [Artist] = []
        var bookmarks: [Bookmark] = []
        var tracksByID: [String: Track] = [:]
        var speakerNames: [String: String] = [:]
        var albumsByID: [String: Album] = [:]
        var cachedKeys: Set<String> = []
        var onDeviceProviderIDs: Set<String> = []

        /// Needs a network to play: neither on the phone already nor in the audio cache.
        func isCloud(_ track: Track) -> Bool {
            !onDeviceProviderIDs.contains(track.providerID)
                && !AudioCache.shared.isCached(cachedKeys, providerID: track.providerID, filePath: track.filePath)
        }
    }

    enum Source: Sendable, Hashable {
        case playlist(String)
        case collection(String)
        case speaker(String)
    }

    private let library = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let tracks = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlists = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarks = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providers = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)

    func snapshot() async -> Snapshot {
        let cachedKeys = await AudioCache.shared.cachedKeys()
        let this = self
        return await Task.detached(priority: .userInitiated) {
            var s = Snapshot()
            s.cachedKeys = cachedKeys
            s.onDeviceProviderIDs = Set(((try? this.providers.all()) ?? [])
                .filter { [LocalFilesProvider.providerType, DemoProvider.providerType].contains($0.type) }
                .map(\.id))
            // A video has nothing to play in the car.
            let all = ((try? this.tracks.all()) ?? []).filter { $0.youTubeID == nil }
            s.tracksByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            s.continueListening = ((try? this.tracks.recentlyPlayed()) ?? []).filter { $0.youTubeID == nil && $0.listenedAt == nil }
            s.listenLater = ((try? this.tracks.listenLater()) ?? []).filter { $0.youTubeID == nil }
            s.favorites = ((try? this.tracks.favorites()) ?? []).filter { $0.youTubeID == nil }
            s.downloaded = all.filter {
                AudioCache.shared.isCached(cachedKeys, providerID: $0.providerID, filePath: $0.filePath)
            }
            s.playlists = (try? this.playlists.all()) ?? []
            s.collections = (try? this.library.albums()) ?? []
            s.albumsByID = Dictionary(s.collections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            s.speakers = SpeakerOrder.byLastActivity((try? this.library.artists()) ?? [], tracks: all)
            s.speakerNames = Dictionary(s.speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            s.bookmarks = ((try? this.bookmarks.recent(limit: 100)) ?? []).filter { s.tracksByID[$0.trackID] != nil }
            return s
        }.value
    }

    func episodes(of source: Source) async -> [Track] {
        let this = self
        return await Task.detached(priority: .userInitiated) {
            let episodes: [Track]
            switch source {
            case .playlist(let id): episodes = (try? this.playlists.tracks(inPlaylist: id)) ?? []
            case .collection(let id): episodes = (try? this.tracks.tracks(forAlbum: id)) ?? []
            case .speaker(let id): episodes = (try? this.tracks.tracks(forArtist: id)) ?? []
            }
            return episodes.filter { $0.youTubeID == nil }
        }.value
    }

    /// The slice of a long list the car can show: CarPlay caps a list's length, and
    /// episode 1 of 412 is rarely the one wanted. Starts a couple of episodes before the
    /// first unfinished one, so where you got to is on screen with a little context.
    static func window(_ count: Int, firstUnplayed: Int?, limit: Int) -> Range<Int> {
        guard count > limit, limit > 0 else { return 0..<count }
        let anchor = max((firstUnplayed ?? 0) - 2, 0)
        let start = min(anchor, count - limit)
        return start..<(start + limit)
    }

    /// "Tim Keller · 23 min left" / "Played · 38 min" / "52 min".
    static func detail(for track: Track, speaker: String?) -> String {
        let total = track.durationMs.map { max($0 / 60_000, 1) }
        if track.listenedAt != nil {
            return [String(localized: "Played"), total.map(minutes)].compactMap { $0 }.joined(separator: " · ")
        }
        var length = total.map(minutes)
        if let total, let durationMs = track.durationMs, let positionMs = track.positionMs, positionMs > 2_000 {
            let left = max((durationMs - positionMs) / 60_000, 1)
            length = left < total ? String(localized: "\(left) min left") : minutes(total)
        }
        return [speaker, length].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private static func minutes(_ n: Int) -> String { String(localized: "\(n) min") }

    static func progress(of track: Track) -> CGFloat? {
        guard track.listenedAt == nil, let durationMs = track.durationMs, durationMs > 0,
              let positionMs = track.positionMs, positionMs > 2_000 else { return nil }
        return min(CGFloat(positionMs) / CGFloat(durationMs), 1)
    }
}
