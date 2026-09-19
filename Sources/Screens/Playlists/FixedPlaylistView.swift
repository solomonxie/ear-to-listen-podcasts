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

    /// Only downloads have anything to remove — a favourite is unfavourited on the episode
    /// itself, and there's no local copy here to free up. Spelled out rather than inlined
    /// as a ternary: `onDelete` takes an optional closure, and the inline form gave the
    /// type checker more than it could chew.
    private var deleteAction: ((IndexSet) -> Void)? {
        guard kind == .downloaded else { return nil }
        return { offsets in removeDownloads(at: offsets) }
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
        case .favorites:
            entries = ((try? trackStore.favorites()) ?? []).map { Entry(track: $0) }
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
/// so they read as one row of playlists, with the symbol and tint as the only difference —
/// these two are the app's, the rest are yours.
struct FixedPlaylistCard: View {
    let kind: FixedPlaylist
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(kind.tint.gradient)
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: kind.symbol).font(.largeTitle).foregroundStyle(.white)
                }
            Text(kind.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            // Zero is worth printing: it's the difference between "empty" and "broken".
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 120)
    }
}
