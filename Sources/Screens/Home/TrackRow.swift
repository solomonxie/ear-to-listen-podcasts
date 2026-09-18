import SwiftUI

/// Shared row for browsing real synced tracks — albums, speakers, shows, playlists,
/// year/topic lists.
///
/// Under the title: which collection, and whose voice. Files routinely share an embedded
/// title tag — a batch export stamps a whole folder with one — so a row needs a second
/// line to tell two of them apart, and "Season 3 · Andrew Huberman" answers that while
/// also saying something worth knowing. The file path only comes back when neither is
/// known, which is the one case where it's the only thing that differs.
struct TrackRow: View {
    let track: Track

    @ObservedObject private var names = LibraryNames.shared
    @State private var showingEdit = false

    private var album: Album? { names.album(track.albumID) }

    var body: some View {
        HStack(spacing: 10) {
            ArtworkTile(track: track, album: album, cornerRadius: 6, symbolSize: 16)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle = names.subtitle(for: track) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    // Truncated at the head so the filename — the telling end — survives.
                    Text(Self.pathHint(for: track))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
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

    /// The whole path, for the rows with nothing better to say and for anywhere that wants
    /// to show where a file actually sits.
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
