import Foundation

/// Backs every Home shelf from the real synced library (`LibraryStore`/`TrackStore`/
/// `PlaylistStore`) — no mock data. Demo content (`DemoDataSeeder`) flows through the
/// exact same tables, so it shows up here the same way a real synced source would.
@MainActor
final class HomeLibraryViewModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var downloadedTracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var shows: [Show] = []
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var years: [Int] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// Nothing synced and no sample library loaded — a fresh install, where shelves of
    /// empty headings would read as a broken screen rather than an empty one.
    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty
            && shows.isEmpty && topics.isEmpty && playlists.isEmpty
    }

    func refresh() async {
        tracks = (try? trackStore.all()) ?? []
        recentTracks = (try? trackStore.recentlyPlayed()) ?? []
        albums = (try? libraryStore.albums()) ?? []
        artists = (try? libraryStore.artists()) ?? []
        shows = (try? libraryStore.shows()) ?? []
        topics = (try? libraryStore.topics()) ?? []
        playlists = (try? playlistStore.all()) ?? []
        years = (try? trackStore.years()) ?? []

        var downloaded: [Track] = []
        for track in tracks {
            if await AudioCache.shared.cachedURL(providerID: track.providerID, filePath: track.filePath) != nil {
                downloaded.append(track)
            }
        }
        downloadedTracks = downloaded
    }

    func createPlaylist(name: String) {
        let playlist = Playlist(id: UUID().uuidString, name: name, source: "local", createdAt: Date())
        try? playlistStore.create(playlist)
        Task { await refresh() }
    }

    func favoriteShows() -> [Show] { shows.filter(\.isSaved) }

    func tracks(forShow showID: String) -> [Track] { tracks.filter { $0.showID == showID } }
    func tracks(forTopic topicID: String) -> [Track] {
        let showIDs = Set(((try? libraryStore.shows(forTopic: topicID)) ?? []).map(\.id))
        return tracks.filter { track in track.showID.map(showIDs.contains) ?? false }
    }
    func tracks(forYear year: Int) -> [Track] { tracks.filter { $0.year == year } }
}
