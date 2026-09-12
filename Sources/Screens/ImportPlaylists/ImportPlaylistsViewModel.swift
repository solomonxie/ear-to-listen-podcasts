import Foundation

@MainActor
final class ImportPlaylistsViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var playlists: [ImportedPlaylist] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastImportSummary: String?

    private let spotify = SpotifyImportSource()
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    func checkAuth() async {
        isAuthenticated = await spotify.isAuthenticated()
        if isAuthenticated {
            await loadPlaylists()
        }
    }

    func connect() async {
        do {
            try await spotify.authenticate()
            isAuthenticated = true
            await loadPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadPlaylists() async {
        isLoading = true
        defer { isLoading = false }
        do {
            playlists = try await spotify.listPlaylists()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPlaylist(_ playlist: ImportedPlaylist) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let importedTracks = try await spotify.tracks(forPlaylistID: playlist.id)
            let library = try trackStore.all()
            let artists = try libraryStore.artists().reduce(into: [String: String]()) { $0[$1.id] = $1.name }

            let local = Playlist(id: UUID().uuidString, name: playlist.name, source: "spotify", createdAt: Date())
            try playlistStore.create(local)

            var matched = 0
            var unmatched: [String] = []
            for (index, imported) in importedTracks.enumerated() {
                if let match = TrackMatcher.bestMatch(for: imported, in: library, artistNames: artists),
                   match.confidence >= TrackMatcher.autoAcceptThreshold {
                    try playlistStore.addTrack(match.track.id, toPlaylist: local.id, at: index)
                    matched += 1
                } else {
                    unmatched.append("\(imported.artist) - \(imported.title)")
                }
            }

            var summary = "Imported \"\(playlist.name)\": \(matched)/\(importedTracks.count) matched."
            if !unmatched.isEmpty {
                summary += " Not found in your library: " + unmatched.prefix(5).joined(separator: ", ")
                if unmatched.count > 5 { summary += ", and \(unmatched.count - 5) more." }
            }
            lastImportSummary = summary
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
