import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @State private var tracks: [Track] = []
    @State private var artistName: String?

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
                        if let artistName {
                            Text(artistName).font(.caption.weight(.semibold))
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
        .task {
            tracks = (try? trackStore.tracks(forAlbum: album.id)) ?? []
            artistName = album.artistID.flatMap { try? libraryStore.artist(id: $0) }?.name
        }
    }
}
