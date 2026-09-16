import SwiftUI

/// Picks (or creates) a playlist for one track — from `RealPlayerView`'s "Add to Playlist"
/// button. The reverse direction of `AddTracksToPlaylistView`, which browses the library to
/// add tracks into a given playlist.
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var showingCreate = false
    @State private var newPlaylistName = ""

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showingCreate = true
                } label: {
                    Label("New Playlist", systemImage: "plus.circle")
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
            .alert("New Playlist", isPresented: $showingCreate) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let playlist = Playlist(id: UUID().uuidString, name: name, source: "local", createdAt: Date())
                    try? playlistStore.create(playlist)
                    newPlaylistName = ""
                    add(to: playlist)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlist: Playlist) {
        let position = (try? playlistStore.tracks(inPlaylist: playlist.id).count) ?? 0
        try? playlistStore.addTrack(track.id, toPlaylist: playlist.id, at: position)
        dismiss()
    }
}
