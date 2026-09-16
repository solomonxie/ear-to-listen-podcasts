import SwiftUI

/// Browses Speakers/Albums/other Playlists to add tracks into `playlist` — the reverse
/// direction of `AddToPlaylistSheet`, which picks a playlist for one already-known track.
struct AddTracksToPlaylistView: View {
    let playlist: Playlist
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category = .speakers
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var otherPlaylists: [Playlist] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    private enum Category: String, CaseIterable {
        case speakers = "Speakers"
        case albums = "Albums"
        case playlists = "Playlists"
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Category", selection: $category) {
                    ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch category {
                case .speakers:
                    ForEach(artists) { artist in
                        NavigationLink(artist.name) {
                            TrackPickerList(title: artist.name, playlist: playlist) {
                                (try? trackStore.tracks(forArtist: artist.id)) ?? []
                            }
                        }
                    }
                case .albums:
                    ForEach(albums) { album in
                        NavigationLink(album.name) {
                            TrackPickerList(title: album.name, playlist: playlist) {
                                (try? trackStore.tracks(forAlbum: album.id)) ?? []
                            }
                        }
                    }
                case .playlists:
                    ForEach(otherPlaylists) { other in
                        NavigationLink(other.name) {
                            TrackPickerList(title: other.name, playlist: playlist) {
                                (try? playlistStore.tracks(inPlaylist: other.id)) ?? []
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        artists = (try? libraryStore.artists()) ?? []
        albums = (try? libraryStore.albums()) ?? []
        otherPlaylists = ((try? playlistStore.all()) ?? []).filter { $0.id != playlist.id }
    }
}

/// One category's tracks, each toggleable in/out of the target playlist.
private struct TrackPickerList: View {
    let title: String
    let playlist: Playlist
    let loadTracks: () -> [Track]

    @State private var tracks: [Track] = []
    @State private var addedTrackIDs: Set<String> = []

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List(tracks) { track in
            Button {
                toggle(track)
            } label: {
                HStack {
                    TrackRow(track: track)
                    Spacer()
                    Image(systemName: addedTrackIDs.contains(track.id) ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(addedTrackIDs.contains(track.id) ? Color.accentColor : .secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tracks = loadTracks()
            addedTrackIDs = Set(((try? playlistStore.tracks(inPlaylist: playlist.id)) ?? []).map(\.id))
        }
    }

    private func toggle(_ track: Track) {
        if addedTrackIDs.contains(track.id) {
            try? playlistStore.removeTrack(track.id, fromPlaylist: playlist.id)
            addedTrackIDs.remove(track.id)
        } else {
            let position = (try? playlistStore.tracks(inPlaylist: playlist.id).count) ?? 0
            try? playlistStore.addTrack(track.id, toPlaylist: playlist.id, at: position)
            addedTrackIDs.insert(track.id)
        }
    }
}
