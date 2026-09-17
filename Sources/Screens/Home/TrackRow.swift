import SwiftUI

/// Shared row for browsing real synced tracks — albums, speakers, shows, playlists,
/// year/topic lists.
struct TrackRow: View {
    let track: Track

    @State private var showingEdit = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkTile(track: track, cornerRadius: 6, symbolSize: 16)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                // Truncated at the head so the filename — the telling end — survives.
                Text(TrackRow.pathHint(for: track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: 6) {
                    if let durationMs = track.durationMs, durationMs > 0 {
                        Text(Self.formattedDuration(durationMs))
                    }
                    if track.isLost {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit Details", systemImage: "pencil") { showingEdit = true }
        }
        .sheet(isPresented: $showingEdit) { EpisodeEditView(track: track) }
    }

    /// Files routinely share an embedded title tag — a batch export stamps the whole
    /// folder with one, and then every row reads the same. The path is the one thing
    /// that's always different, so every list showing a title shows this underneath it.
    static func pathHint(for track: Track) -> String { track.filePath }

    /// Just the filename, for the places too narrow for a whole path (the mini player,
    /// Up Next).
    static func fileName(for track: Track) -> String { (track.filePath as NSString).lastPathComponent }

    static func formattedDuration(_ ms: Int) -> String {
        let minutes = ms / 1000 / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
