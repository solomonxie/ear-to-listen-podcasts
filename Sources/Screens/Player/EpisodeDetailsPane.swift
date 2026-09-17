import SwiftUI

/// Everything known about what's playing — the tags that came off the file, where the
/// file actually lives, and the dates that explain why it looks the way it does. Grouped
/// cards rather than one flat list, so "who/what" doesn't blur into "which file".
struct EpisodeDetailsPane: View {
    let playingTrack: Track

    /// Re-read rather than taken from `PlaybackEngine`, whose copy was loaded before
    /// playback started — "Stopped at" would otherwise show where the last session ended.
    @State private var latest: Track?
    @State private var artist: Artist?
    @State private var album: Album?
    @State private var show: Show?
    @State private var topics: [Topic] = []
    @State private var connectionLabel: String?
    @State private var downloadedBytes: Int64?
    @State private var showingEdit = false

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    private var track: Track { latest ?? playingTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if track.isLost {
                Label("Missing from the last sync — the file wasn't in the bucket listing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            DetailCard("Episode") {
                if let artist {
                    NavigationLink { SpeakerDetailView(speaker: artist) } label: {
                        DetailRow("Speaker", artist.name, isLink: true)
                    }
                    .buttonStyle(.plain)
                }
                if let album {
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        DetailRow("Album", album.name, isLink: true)
                    }
                    .buttonStyle(.plain)
                }
                if let show {
                    NavigationLink { ShowDetailView(show: show) } label: {
                        DetailRow("Show", show.name, isLink: true)
                    }
                    .buttonStyle(.plain)
                }
                DetailRow("Year", track.year.map(String.init))
                DetailRow("Duration", track.durationMs.map(TrackRow.formattedDuration))
                DetailRow("Track no.", track.trackNumber.map(String.init))
                if !topics.isEmpty {
                    TagRow(names: topics.map(\.name))
                }
                Button("Edit Details", systemImage: "pencil") { showingEdit = true }
                    .font(.footnote)
            }

            if let notes = track.notes, !notes.isEmpty {
                DetailCard("Notes") {
                    Text(notes).font(.footnote).foregroundStyle(.secondary)
                }
            }

            DetailCard("File") {
                DetailRow("Connection", connectionLabel)
                DetailRow("Folder", folder)
                DetailRow("File", (track.filePath as NSString).lastPathComponent)
                DetailRow("Format", fileExtension)
                DetailRow("Size", track.sizeBytes.map { $0.formatted(.byteCount(style: .file)) })
                DetailRow("Downloaded", downloadedBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "Not downloaded")
            }

            DetailCard("Dates") {
                DetailRow("Changed on storage", Self.formatted(track.remoteModifiedAt))
                DetailRow("Last synced", Self.formatted(track.updatedAt))
                DetailRow("Last played", Self.formatted(track.lastPlayedAt) ?? "Never")
                DetailRow("Details edited", Self.formatted(track.metadataEditedAt))
                DetailRow("Stopped at", track.positionMs.map { Scrubber.formatted(Double($0) / 1000) })
            }

            if let summary = show?.summary, !summary.isEmpty {
                DetailCard("About the show") {
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .task(id: playingTrack.id) { await load() }
        // Saving an edit doesn't change which track is playing, so `task(id:)` won't fire —
        // this is what puts a new title/speaker/notes on screen right away.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showingEdit) { EpisodeEditView(track: track) }
    }

    private var folder: String? {
        let folder = (track.filePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    private var fileExtension: String? {
        let ext = (track.filePath as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    private static func formatted(_ date: Date?) -> String? {
        date.map { $0.formatted(date: .abbreviated, time: .shortened) }
    }

    private func load() async {
        latest = (try? trackStore.find(id: playingTrack.id)) ?? nil
        artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
        album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
        show = track.showID.flatMap { try? libraryStore.show(id: $0) } ?? nil
        topics = show.flatMap { try? libraryStore.topics(forShow: $0.id) } ?? []
        connectionLabel = (try? providerStore.all())?.first { $0.id == track.providerID }?.label
        downloadedBytes = await AudioCache.shared.cachedSize(providerID: track.providerID, filePath: track.filePath)
    }
}

private struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).sectionHeading()
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Skips itself when there's no value, so an episode with thin metadata shows a short
/// card rather than a column of dashes.
private struct DetailRow: View {
    let label: String
    let value: String?
    var isLink = false

    init(_ label: String, _ value: String?, isLink: Bool = false) {
        self.label = label
        self.value = value
        self.isLink = isLink
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label).sectionRowSecondary()
                Spacer(minLength: 12)
                Text(value)
                    .font(.footnote)
                    .foregroundStyle(isLink ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if isLink {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct TagRow: View {
    let names: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Topics").sectionRowSecondary()
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}
