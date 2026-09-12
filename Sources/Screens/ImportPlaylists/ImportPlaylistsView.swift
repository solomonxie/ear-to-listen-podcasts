import SwiftUI

struct ImportPlaylistsView: View {
    @StateObject private var viewModel = ImportPlaylistsViewModel()

    var body: some View {
        List {
            if !viewModel.isAuthenticated {
                Section {
                    Button("Connect Spotify") {
                        Task { await viewModel.connect() }
                    }
                    Text("Requires a Spotify Client ID configured in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Your Spotify Playlists") {
                    ForEach(viewModel.playlists) { playlist in
                        Button {
                            Task { await viewModel.importPlaylist(playlist) }
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                if let count = playlist.trackCount {
                                    Text("\(count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            if let summary = viewModel.lastImportSummary {
                Section("Last Import") {
                    Text(summary).font(.footnote)
                }
            }
        }
        .navigationTitle("Import Playlists")
        .overlay {
            if viewModel.isLoading {
                ProgressView()
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
        .task { await viewModel.checkAuth() }
    }
}
