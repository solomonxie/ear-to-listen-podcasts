import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var isSyncing = false
    @Published var errorMessage: String?

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    func load() {
        do {
            tracks = try trackStore.all()
            playlists = try playlistStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await SyncEngine().syncActiveProviders()
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addToPlaylist(_ track: Track, _ playlist: Playlist) {
        do {
            let position = try playlistStore.tracks(inPlaylist: playlist.id).count
            try playlistStore.addTrack(track.id, toPlaylist: playlist.id, at: position)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
