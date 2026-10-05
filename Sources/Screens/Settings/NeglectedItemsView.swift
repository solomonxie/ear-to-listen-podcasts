import SwiftUI

/// Everything neglected, with a way back for each.
struct NeglectedItemsView: View {
    @State private var speakers: [Artist] = []
    @State private var albums: [Album] = []
    @State private var episodes: [Track] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List {
            if speakers.isEmpty && albums.isEmpty && episodes.isEmpty {
                Text("Nothing neglected.").foregroundStyle(.secondary)
            }
            if !speakers.isEmpty {
                Section("Speakers") {
                    ForEach(speakers) { speaker in
                        row(speaker.name) { try libraryStore.setArtistNeglected(id: speaker.id, neglected: false) }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        row(album.name) { try libraryStore.setAlbumNeglected(id: album.id, neglected: false) }
                    }
                }
            }
            if !episodes.isEmpty {
                Section("Episodes") {
                    ForEach(episodes) { track in
                        row(track.title) { try trackStore.setNeglected(ids: [track.id], neglected: false) }
                    }
                }
            }
        }
        .navigationTitle("Neglected items")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func row(_ title: String, restore: @escaping () throws -> Void) -> some View {
        HStack {
            Text(title).lineLimit(2)
            Spacer()
            Button("Bring Back") {
                try? restore()
                FixHistoryStore(dbQueue: DatabaseManager.shared.dbQueue).record(action: "Bring back", count: 1, detail: title)
                load()
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
            .buttonStyle(.borderless)
        }
    }

    private func load() {
        speakers = (try? libraryStore.neglectedArtists()) ?? []
        albums = (try? libraryStore.neglectedAlbums()) ?? []
        episodes = (try? trackStore.neglectedEpisodes()) ?? []
    }
}
