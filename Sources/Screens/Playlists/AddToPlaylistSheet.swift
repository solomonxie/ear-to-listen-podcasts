import SwiftUI

/// Picks (or creates) a playlist for one track — from `RealPlayerView`'s "Add to Playlist"
/// button. The reverse direction of `AddTracksToPlaylistView`, which browses the library to
/// add tracks into a given playlist.
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var openRow: String?
    @State private var newPlaylistName = ""

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        NavigationStack {
            List {
                // Unfolds into a name field right here, rather than stacking an alert on
                // top of a sheet — the list you're adding to stays visible while you name
                // the thing you're adding it to.
                UnfoldingTextField(
                    prompt: "New Playlist", actionLabel: "Create",
                    id: "newPlaylist", open: $openRow
                ) { name in
                    let playlist = Playlist(
                        id: UUID().uuidString, name: name, source: "local", createdAt: Date()
                    )
                    try? playlistStore.create(playlist)
                    add(to: playlist)
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                Text(playlist.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { playlists = (try? playlistStore.all()) ?? [] }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlist: Playlist) {
        let position = (try? playlistStore.tracks(inPlaylist: playlist.id).count) ?? 0
        try? playlistStore.addTrack(track.id, toPlaylist: playlist.id, at: position)
        dismiss()
    }
}
