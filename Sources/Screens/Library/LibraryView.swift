import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.tracks.isEmpty {
                    ContentUnavailableView(
                        "No tracks yet",
                        systemImage: "music.note.list",
                        description: Text("Add a storage provider in Settings, then pull to sync.")
                    )
                } else {
                    List(viewModel.tracks) { track in
                        Button {
                            playback.play(track: track, queue: viewModel.tracks)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(track.title)
                                if let ms = track.durationMs {
                                    Text(Self.formattedDuration(ms))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Menu("Add to Playlist") {
                                ForEach(viewModel.playlists) { playlist in
                                    Button(playlist.name) { viewModel.addToPlaylist(track, playlist) }
                                }
                            }
                        }
                    }
                    .refreshable { await viewModel.sync() }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if viewModel.isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await viewModel.sync() }
                        } label: {
                            Label("Sync", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { _ in viewModel.errorMessage = nil }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onAppear { viewModel.load() }
        }
    }

    private static func formattedDuration(_ ms: Int) -> String {
        let totalSeconds = ms / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
