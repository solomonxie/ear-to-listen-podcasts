import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @State private var tracks: [Track] = []
    @State private var artistName: String?
    @State private var showingEditSpeaker = false
    @State private var editedSpeakerName = ""

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LibraryArt.color(for: album.id).gradient)
                        .frame(height: 160)
                        .overlay { Image(systemName: "square.stack.fill").font(.system(size: 48)).foregroundStyle(.white) }
                    HStack {
                        // Tappable rather than plain text — embedded/guessed speaker
                        // metadata is sometimes wrong (a shared uploader/collection name
                        // instead of the actual speaker), so it needs to be correctable.
                        Button {
                            editedSpeakerName = artistName ?? ""
                            showingEditSpeaker = true
                        } label: {
                            Text(artistName ?? "Set speaker")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(artistName == nil ? .secondary : .primary)
                        }
                        Spacer()
                        Text("\(tracks.count) episode\(tracks.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let first = tracks.first {
                        Button {
                            PlaybackEngine.shared.play(track: first, queue: tracks)
                        } label: {
                            Label("Play latest", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .listRowSeparator(.hidden)
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
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Speaker", isPresented: $showingEditSpeaker) {
            TextField("Speaker name", text: $editedSpeakerName)
            Button("Save") {
                let name = editedSpeakerName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                _ = try? libraryStore.reassignAlbumArtist(albumID: album.id, artistName: name)
                artistName = name
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Fixes every episode in this album — use this if the speaker shown was guessed wrong from the file's metadata.")
        }
    }

    private func load() async {
        tracks = (try? trackStore.tracks(forAlbum: album.id)) ?? []
        artistName = album.artistID.flatMap { try? libraryStore.artist(id: $0) }?.name
    }
}
