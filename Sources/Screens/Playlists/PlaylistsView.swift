import SwiftUI

@MainActor
final class PlaylistsViewModel: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var errorMessage: String?

    private let playlistStore = PlaylistStore(dbQueue: DatabaseManager.shared.dbQueue)

    func load() {
        do {
            playlists = try playlistStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String) {
        do {
            try playlistStore.create(Playlist(id: UUID().uuidString, name: name, source: "local", createdAt: Date()))
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            try? playlistStore.delete(id: playlists[index].id)
        }
        load()
    }
}

struct PlaylistsView: View {
    @StateObject private var viewModel = PlaylistsViewModel()
    @State private var showingCreate = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.playlists) { playlist in
                    NavigationLink(playlist.name) {
                        PlaylistDetailView(playlist: playlist)
                    }
                }
                .onDelete { viewModel.delete(at: $0) }

                Section {
                    NavigationLink("Import from Spotify") {
                        ImportPlaylistsView()
                    }
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Playlist", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                Button("Create") {
                    guard !newName.isEmpty else { return }
                    viewModel.create(name: newName)
                    newName = ""
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { viewModel.load() }
        }
    }
}
