import SwiftUI

/// Every synced track currently cached on-disk (`AudioCache`) — anything played once
/// downloads a background copy for offline replay, so this list is exactly "what's on
/// this device" rather than a separate download queue. Removing an entry just drops that
/// local copy; the track stays synced and re-downloads the next time it's played.
struct DownloadsView: View {
    @State private var entries: [(track: Track, sizeBytes: Int64)] = []
    @State private var isLoading = true

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            } else if entries.isEmpty {
                Text("No downloaded episodes yet. Anything you play is saved here automatically.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.track.id) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.track.title).lineLimit(1)
                            Text(TrackRow.pathHint(for: entry.track))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("Downloaded")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        let tracks = (try? trackStore.all()) ?? []
        var result: [(track: Track, sizeBytes: Int64)] = []
        for track in tracks {
            if let size = await AudioCache.shared.cachedSize(providerID: track.providerID, filePath: track.filePath) {
                result.append((track, size))
            }
        }
        entries = result.sorted { $0.track.title < $1.track.title }
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        Task {
            for entry in removed {
                await AudioCache.shared.invalidate(providerID: entry.track.providerID, filePath: entry.track.filePath)
            }
        }
    }
}
