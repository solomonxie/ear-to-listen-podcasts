import Foundation

/// Backs every Home shelf from the real synced library (`LibraryStore`/`TrackStore`/
/// `PlaylistStore`) — no mock data and no sample library: the shelves stay empty until a
/// source is connected and its first files land in those tables.
@MainActor
final class HomeLibraryViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var downloadedTracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var years: [Int] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var favoriteTracks: [Track] = []
    @Published private(set) var listenLaterTracks: [Track] = []
    /// Folded once here rather than rebuilt per keystroke — see `LibrarySearch`.
    @Published private(set) var searchIndex = LibrarySearch.Index()
    /// Bookmarks as Home shows them: per episode, in episode order.
    @Published private(set) var bookmarkGroups: [BookmarkGroup] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)
    private var refreshTask: Task<Void, Never>?

    func refresh() async {
        tracks = (try? trackStore.all()) ?? []
        recentTracks = (try? trackStore.recentlyPlayed()) ?? []
        albums = (try? libraryStore.albums()) ?? []
        artists = (try? libraryStore.artists()) ?? []
        topics = (try? libraryStore.topics()) ?? []
        playlists = (try? playlistStore.all()) ?? []
        years = (try? trackStore.years()) ?? []
        bookmarks = (try? bookmarkStore.recent()) ?? []
        favoriteTracks = (try? trackStore.favorites()) ?? []
        listenLaterTracks = (try? trackStore.listenLater()) ?? []

        // One directory listing, then a pure hash check per track. Asking the cache per
        // track cost four filesystem calls each — including an attribute *write* that
        // bumped the LRU date — so this loop alone could stall Home for seconds on a large
        // library, every time a sync posted `.libraryDidChange`.
        let cachedKeys = await AudioCache.shared.cachedKeys()
        downloadedTracks = tracks.filter {
            AudioCache.shared.isCached(cachedKeys, providerID: $0.providerID, filePath: $0.filePath)
        }

        regroupBookmarks()
        // Every mark, not just the recent ones Home shows: search looks through the whole
        // library, and a note from last year is exactly the kind of thing being looked for.
        searchIndex = LibrarySearch.index(
            speakers: artists, albums: albums, playlists: playlists, topics: topics,
            tracks: tracks, notes: (try? bookmarkStore.all()) ?? []
        )
    }

    /// What was *said* matching the query. A database scan rather than a folded index —
    /// transcripts are megabytes — so it runs off the main actor and arrives a moment
    /// after the rest of the results.
    func transcriptMatches(for query: String) async -> [TranscriptSearch.Match] {
        let search = TranscriptSearch(dbQueue: DatabaseManager.shared.dbQueue)
        return await Task.detached(priority: .userInitiated) {
            (try? search.matches(for: query)) ?? []
        }.value
    }

    /// Coalesces a burst of refreshes into one. A sync posts `.libraryDidChange` per
    /// imported file, so a hundred-file pass used to run `refresh()` a hundred times —
    /// each one re-reading every table. The last one is the only one that matters.
    func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func createPlaylist(name: String) {
        let playlist = Playlist(id: UUID().uuidString, name: name, source: "local", createdAt: Date())
        try? playlistStore.create(playlist)
        Task { await refresh() }
    }

    /// What a fixed playlist's card shows. Both are derived rather than stored, so there's
    /// nothing to count but the thing itself.
    func count(of kind: FixedPlaylist) -> Int {
        switch kind {
        case .listenLater: return listenLaterTracks.count
        case .favorites: return favoriteTracks.count
        case .downloaded: return downloadedTracks.count
        }
    }

    func track(id: String) -> Track? { tracks.first { $0.id == id } }

    func refreshBookmarks() {
        bookmarks = (try? bookmarkStore.recent()) ?? []
        regroupBookmarks()
    }

    private func regroupBookmarks() {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        bookmarkGroups = BookmarkGroup.group(bookmarks) { byID[$0] }
    }

    /// A topic tags albums now, so its episodes are the episodes of those albums.
    func tracks(forTopic topicID: String) -> [Track] {
        let albumIDs = (try? libraryStore.albumIDs(forTopic: topicID)) ?? []
        return tracks.filter { track in track.albumID.map(albumIDs.contains) ?? false }
    }
    func tracks(forYear year: Int) -> [Track] { tracks.filter { $0.year == year } }
}
