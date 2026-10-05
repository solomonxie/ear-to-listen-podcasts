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
    /// The ten albums most recently played from or edited, newest first.
    @Published private(set) var recentAlbums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var topics: [Topic] = []
    /// Whatever the library talks about most, biggest first — Home's Terms chart.
    @Published private(set) var terms: [TermCount] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var years: [Int] = []
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var favoriteTracks: [Track] = []
    @Published private(set) var listenLaterTracks: [Track] = []
    @Published private(set) var listenedCount = 0
    @Published private(set) var youTubeCount = 0
    /// Everything played, most recent first — Home's Listen History. From `tracks`, which
    /// is already loaded, rather than another query.
    @Published private(set) var history: [Track] = []
    /// Folded once here rather than rebuilt per keystroke — see `LibrarySearch`.
    @Published private(set) var searchIndex = LibrarySearch.Index()
    /// Bookmarks as Home shows them: per episode, in episode order.
    @Published private(set) var bookmarkGroups: [BookmarkGroup] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let termStore = TermStore()
    private var refreshTask: Task<Void, Never>?
    /// Enough history to be useful when expanded; past this it's a list nobody scrolls.
    nonisolated static let historyLimit = 100

    /// **Read and folded off the main actor, published in one go.** This used to be a
    /// dozen queries, the whole-library search fold and the bookmark grouping on the main
    /// thread — at launch, before Home could draw, and again every time the player closed.
    /// Each `@Published` set was its own redraw too.
    func refresh() async {
        if tracks.isEmpty { await showFirstShelves() }
        let cachedKeys = await AudioCache.shared.cachedKeys()
        let load = Snapshot.loader(
            libraryStore: libraryStore, trackStore: trackStore, playlistStore: playlistStore,
            bookmarkStore: bookmarkStore, termStore: termStore
        )
        let snapshot = await Task.detached(priority: .userInitiated) { load(cachedKeys) }.value
        tracks = snapshot.tracks
        recentTracks = snapshot.recentTracks
        albums = snapshot.albums
        recentAlbums = snapshot.recentAlbums
        artists = snapshot.artists
        topics = snapshot.topics
        terms = snapshot.terms
        playlists = snapshot.playlists
        years = snapshot.years
        bookmarks = snapshot.bookmarks
        favoriteTracks = snapshot.favoriteTracks
        listenLaterTracks = snapshot.listenLaterTracks
        listenedCount = snapshot.listenedCount
        youTubeCount = snapshot.youTubeCount
        history = snapshot.history
        downloadedTracks = snapshot.downloadedTracks
        bookmarkGroups = snapshot.bookmarkGroups
        searchIndex = snapshot.searchIndex
    }

    /// The top of Home — Continue Listening and the speakers — from a few small queries,
    /// on screen before the whole library has been read. Only on the first load: after
    /// that, the full refresh has them already.
    private func showFirstShelves() async {
        let trackStore = trackStore, libraryStore = libraryStore
        let (recent, albums, speakers) = await Task.detached(priority: .userInitiated) {
            let played = (try? trackStore.played()) ?? []
            return (
                (try? trackStore.recentlyPlayed()) ?? [],
                (try? libraryStore.recentAlbums()) ?? [],
                SpeakerOrder.byLastActivity((try? libraryStore.artists()) ?? [], tracks: played)
            )
        }.value
        guard tracks.isEmpty else { return }
        recentTracks = recent
        recentAlbums = albums
        artists = speakers
    }

    private struct Snapshot: Sendable {
        var tracks: [Track] = []
        var recentTracks: [Track] = []
        var downloadedTracks: [Track] = []
        var albums: [Album] = []
        var recentAlbums: [Album] = []
        var artists: [Artist] = []
        var topics: [Topic] = []
        var terms: [TermCount] = []
        var playlists: [Playlist] = []
        var years: [Int] = []
        var bookmarks: [Bookmark] = []
        var favoriteTracks: [Track] = []
        var listenLaterTracks: [Track] = []
        var listenedCount = 0
        var youTubeCount = 0
        var history: [Track] = []
        var searchIndex = LibrarySearch.Index()
        var bookmarkGroups: [BookmarkGroup] = []

        static func loader(
            libraryStore: LibraryStore, trackStore: TrackStore, playlistStore: PlaylistStore,
            bookmarkStore: BookmarkStore, termStore: TermStore
        ) -> @Sendable (Set<String>) -> Snapshot {
            { cachedKeys in
                var s = Snapshot()
                s.tracks = (try? trackStore.all()) ?? []
                s.recentTracks = (try? trackStore.recentlyPlayed()) ?? []
                s.albums = (try? libraryStore.albums()) ?? []
                s.recentAlbums = (try? libraryStore.recentAlbums()) ?? []
                // Not the order the table hands them back in — see `SpeakerOrder`.
                s.artists = SpeakerOrder.byLastActivity((try? libraryStore.artists()) ?? [], tracks: s.tracks)
                s.topics = (try? libraryStore.topics()) ?? []
                s.terms = (try? termStore.topTerms()) ?? []
                s.playlists = (try? playlistStore.all()) ?? []
                s.years = (try? trackStore.years()) ?? []
                s.bookmarks = (try? bookmarkStore.recent()) ?? []
                s.favoriteTracks = (try? trackStore.favorites()) ?? []
                s.listenLaterTracks = (try? trackStore.listenLater()) ?? []
                s.listenedCount = s.tracks.lazy.filter { $0.listenedAt != nil && !$0.isLost }.count
                s.youTubeCount = s.tracks.lazy.filter { $0.youTubeID != nil }.count
                s.history = s.tracks.filter { $0.lastPlayedAt != nil && !$0.isLost }
                    .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                    .prefix(HomeLibraryViewModel.historyLimit).map { $0 }
                // One directory listing, then a pure hash check per track — never a cache
                // lookup per track.
                s.downloadedTracks = s.tracks.filter {
                    AudioCache.shared.isCached(cachedKeys, providerID: $0.providerID, filePath: $0.filePath)
                }
                s.bookmarkGroups = HomeLibraryViewModel.group(s.bookmarks, tracks: s.tracks)
                // Every mark, not just the recent ones Home shows: search looks through the
                // whole library, and a note from last year is exactly what gets looked for.
                s.searchIndex = LibrarySearch.index(
                    speakers: s.artists, albums: s.albums, playlists: s.playlists, topics: s.topics,
                    tracks: s.tracks, notes: (try? bookmarkStore.all()) ?? []
                )
                return s
            }
        }
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
        case .listened: return listenedCount
        case .downloaded: return downloadedTracks.count
        case .youTube: return youTubeCount
        }
    }

    func track(id: String) -> Track? { tracks.first { $0.id == id } }

    func refreshBookmarks() {
        bookmarks = (try? bookmarkStore.recent()) ?? []
        regroupBookmarks()
    }

    private func regroupBookmarks() {
        bookmarkGroups = Self.group(bookmarks, tracks: tracks)
    }

    nonisolated private static func group(_ bookmarks: [Bookmark], tracks: [Track]) -> [BookmarkGroup] {
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return BookmarkGroup.group(bookmarks) { byID[$0] }
    }

    /// A topic tags albums now, so its episodes are the episodes of those albums.
    func tracks(forTopic topicID: String) -> [Track] {
        let albumIDs = (try? libraryStore.albumIDs(forTopic: topicID)) ?? []
        return tracks.filter { track in track.albumID.map(albumIDs.contains) ?? false }
    }
    func tracks(forYear year: Int) -> [Track] { tracks.filter { $0.year == year } }
}
