import Foundation

struct ImportedTrack: Hashable {
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int?
    var isrc: String?
}

struct ImportedPlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    var trackCount: Int?
}

protocol PlaylistImportSource {
    var type: String { get }
    func isAuthenticated() async -> Bool
    func authenticate() async throws
    func signOut() async
    func listPlaylists() async throws -> [ImportedPlaylist]
    func tracks(forPlaylistID playlistID: String) async throws -> [ImportedTrack]
}

final class PlaylistImportSourceRegistry {
    static let shared = PlaylistImportSourceRegistry()

    private var sources: [String: PlaylistImportSource] = [:]

    func register(_ source: PlaylistImportSource) {
        sources[source.type] = source
    }

    func source(forType type: String) -> PlaylistImportSource? {
        sources[type]
    }

    var registeredTypes: [String] { Array(sources.keys) }
}
