import SwiftUI

struct SpeakerDetailView: View {
    let speaker: Artist
    @State private var currentSpeaker: Artist
    @State private var shows: [Show] = []
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var showingEdit = false

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _currentSpeaker = State(initialValue: speaker)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    SpeakerAvatar(photoFileName: currentSpeaker.photoFileName, size: 96)
                    if let bio = currentSpeaker.bio {
                        Text(bio).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        ForEach(shows) { show in Text(show.name).font(.caption.weight(.semibold)) }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Albums") {
                if albums.isEmpty {
                    Text("No albums yet").foregroundStyle(.secondary)
                }
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        AlbumRow(album: album)
                    }
                }
            }

            Section("Episodes") {
                ForEach(tracks) { track in
                    Button {
                        PlaybackEngine.shared.play(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(currentSpeaker.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingEdit, onDismiss: { Task { await load() } }) {
            SpeakerEditView(speaker: currentSpeaker)
        }
    }

    private func load() async {
        currentSpeaker = (try? libraryStore.artist(id: speaker.id)) ?? currentSpeaker
        shows = (try? libraryStore.shows(forArtist: speaker.id)) ?? []
        albums = (try? libraryStore.albums(forArtist: speaker.id)) ?? []
        tracks = (try? trackStore.tracks(forArtist: speaker.id)) ?? []
    }
}

struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LibraryArt.color(for: album.id).gradient)
                .frame(width: 40, height: 40)
                .overlay { Image(systemName: "square.stack.fill").foregroundStyle(.white) }
            Text(album.name).font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}
