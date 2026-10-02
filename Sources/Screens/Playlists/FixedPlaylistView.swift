import SwiftUI

/// The page behind a `FixedPlaylist` card. Same shape as `PlaylistDetailView` — a list you
/// can play from — minus the things that only make sense for a hand-made playlist: there's
/// nothing to add to it and no order to rearrange, because membership is a fact about the
/// episode rather than a list someone wrote.
///
/// Downloaded carries a size per row and a swipe to free the space back up; removing a
/// download drops the local copy only, and the episode re-downloads the next time it's
/// played.
struct FixedPlaylistView: View {
    let kind: FixedPlaylist

    @State private var entries: [Entry] = []
    @State private var isLoading = true

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    struct Entry: Identifiable {
        let track: Track
        var sizeBytes: Int64?
        var id: String { track.id }
    }

    var body: some View {
        content
            .navigationTitle(kind.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
                Task { await load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label(kind.name, systemImage: kind.symbol)
            } description: {
                Text(kind.emptyMessage)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(entries) { entry in
                row(entry)
            }
            .onDelete(perform: deleteAction)
        }
        .listStyle(.plain)
    }

    /// Downloads and Listen Later each have something to take off here — a local copy, a
    /// place in the queue. A favourite is unfavourited on the episode itself. Spelled out
    /// rather than inlined as a ternary: `onDelete` takes an optional closure, and the
    /// inline form gave the type checker more than it could chew.
    private var deleteAction: ((IndexSet) -> Void)? {
        switch kind {
        case .downloaded: return { offsets in removeDownloads(at: offsets) }
        case .listenLater: return { offsets in removeFromListenLater(at: offsets) }
        case .favorites, .youTube: return nil
        case .listened: return { offsets in unmarkListened(at: offsets) }
        }
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            PlaybackEngine.shared.open(track: entry.track, queue: entries.map(\.track))
        } label: {
            HStack {
                TrackRow(track: entry.track)
                if let sizeBytes = entry.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        defer { isLoading = false }
        switch kind {
        case .listenLater:
            entries = ((try? trackStore.listenLater()) ?? []).map { Entry(track: $0) }
        case .favorites:
            entries = ((try? trackStore.favorites()) ?? []).map { Entry(track: $0) }
        case .listened:
            entries = ((try? trackStore.listened()) ?? []).map { Entry(track: $0) }
        case .youTube:
            entries = ((try? trackStore.youTubeEpisodes()) ?? []).map { Entry(track: $0) }
        case .downloaded:
            // One directory listing rather than a lookup per track — see `AudioCache.cachedKeys`.
            let keys = await AudioCache.shared.cachedKeys()
            let tracks = ((try? trackStore.all()) ?? []).filter {
                AudioCache.shared.isCached(keys, providerID: $0.providerID, filePath: $0.filePath)
            }
            var result: [Entry] = []
            for track in tracks {
                let size = await AudioCache.shared.cachedSize(
                    providerID: track.providerID, filePath: track.filePath
                )
                result.append(Entry(track: track, sizeBytes: size))
            }
            entries = result.sorted { $0.track.title < $1.track.title }
        }
    }

    /// Takes it out of the queue. The episode, and any downloaded copy of it, stays.
    private func removeFromListenLater(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        for entry in removed {
            try? trackStore.setListenLater(id: entry.track.id, listenLater: false)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Back to not listened. The episode stays where it is in the library.
    private func unmarkListened(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0].track.id }
        entries.remove(atOffsets: offsets)
        try? trackStore.setListened(ids: removed, listened: false)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Drops the local copy, not the episode.
    private func removeDownloads(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            for entry in removed {
                await AudioCache.shared.invalidate(
                    providerID: entry.track.providerID, filePath: entry.track.filePath
                )
            }
        }
    }
}

/// A fixed playlist on the Home shelf. Deliberately the same silhouette as `PlaylistCard`
/// so they read as one row of playlists, with the symbol and tint telling them apart —
/// these two are the app's, the rest are yours.
struct FixedPlaylistCard: View {
    let kind: FixedPlaylist
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeneratedCover(seed: kind.rawValue, title: kind.title, kind: .playlist, symbol: kind.symbol, tint: kind.tint)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(kind.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            // Zero is worth printing: it's the difference between "empty" and "broken".
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }
}
