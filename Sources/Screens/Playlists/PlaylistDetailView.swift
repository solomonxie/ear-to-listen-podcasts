import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var showingAddTracks = false

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("No episodes yet", systemImage: "mic.slash")
            } else {
                List(tracks) { track in
                    Button {
                        PlaybackEngine.shared.play(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddTracks = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingAddTracks, onDismiss: { Task { await load() } }) {
            AddTracksToPlaylistView(playlist: playlist)
        }
    }

    private func load() async {
        tracks = (try? playlistStore.tracks(inPlaylist: playlist.id)) ?? []
    }
}
