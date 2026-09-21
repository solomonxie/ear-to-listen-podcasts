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
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// Read fresh rather than from the copy the player is holding, which was loaded when
    /// playback started.
    private var isQueued: Bool {
        ((try? trackStore.find(id: track.id)) ?? nil)?.listenLater ?? track.listenLater
    }

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
                // The app's own list, above the hand-made ones and reachable from the
                // player — the one place you can't long-press a row to get at it.
                Section {
                    Button {
                        try? trackStore.setListenLater(id: track.id, listenLater: !isQueued)
                        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                        dismiss()
                    } label: {
                        Label(
                            isQueued ? "Remove from Listen Later" : "Listen Later",
                            systemImage: isQueued ? "clock.badge.xmark" : "clock"
                        )
                    }
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
