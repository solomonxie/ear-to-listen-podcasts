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
                if track.isLost {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func formattedDuration(_ ms: Int) -> String {
        let minutes = ms / 1000 / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
