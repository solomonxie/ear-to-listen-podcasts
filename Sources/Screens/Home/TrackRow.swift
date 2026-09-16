import SwiftUI

/// Shared row for browsing real synced tracks — albums, speakers, shows, playlists,
/// year/topic lists.
struct TrackRow: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) {
                if let durationMs = track.durationMs, durationMs > 0 {
                    Text(Self.formattedDuration(durationMs))
                }
                if let folderHint {
                    // Truncated at the head so the innermost (most telling) folder survives.
                    Text(folderHint).lineLimit(1).truncationMode(.head)
                }
                if track.isLost {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A file with no usable embedded title falls back to its filename
    /// (`SyncEngine.importFileIfNeeded`), which makes every `ep1.mp3` in a bucket look
    /// identical in a list. When the title is just the filename, the containing folder is
    /// the only thing telling them apart — so show it. Nothing to add when a real tag (or
    /// an AI guess) named the episode, since that's already distinct.
    private var folderHint: String? {
        let fileName = (track.filePath as NSString).lastPathComponent
        guard track.title == (fileName as NSString).deletingPathExtension else { return nil }
        let folder = (track.filePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    static func formattedDuration(_ ms: Int) -> String {
        let minutes = ms / 1000 / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
