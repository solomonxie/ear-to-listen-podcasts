import SwiftUI

struct ShowDetailView: View {
    let show: Show
    @State private var isSaved: Bool
    @State private var tracks: [Track] = []
    @State private var hosts: [Artist] = []

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(show: Show) {
        self.show = show
        _isSaved = State(initialValue: show.isSaved)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LibraryArt.color(for: show.id).gradient)
                        .frame(height: 160)
                        .overlay { Image(systemName: "mic.fill").font(.system(size: 48)).foregroundStyle(.white) }
                    if let summary = show.summary {
                        Text(summary).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        ForEach(hosts) { host in
                            Text(host.name).font(.caption.weight(.semibold))
                        }
                        Spacer()
                        Button(isSaved ? "Saved" : "Save") {
                            isSaved.toggle()
                            try? libraryStore.setShow(show.id, saved: isSaved)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let first = tracks.first {
                        Button {
                            PlaybackEngine.shared.open(track: first, queue: tracks)
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
                        PlaybackEngine.shared.open(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tracks = (try? trackStore.tracks(forShow: show.id)) ?? []
            hosts = (try? libraryStore.artists(forShow: show.id)) ?? []
        }
    }
}
