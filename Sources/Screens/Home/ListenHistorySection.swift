import SwiftUI

/// What was played, most recent first, as plain lines of text: the episode, when it was
/// last listened to, and where it stopped. A tap carries on from that second.
///
/// Text rather than artwork cards: Continue Listening is already the picture shelf of the
/// same episodes, and a history is read down, not browsed across. Shows a few and folds
/// the rest behind one tap, like the Bookmarks section above it.
struct ListenHistorySection: View {
    let tracks: [Track]

    @State private var isExpanded = false

    private static let foldedCount = 5

    private var shown: ArraySlice<Track> { isExpanded ? tracks[...] : tracks.prefix(Self.foldedCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Listen History").font(.title3.bold())
                Spacer()
                Text("\(tracks.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // Lazy: expanded, this is up to a hundred rows on a page that also redraws for
            // everything above it.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { track in
                    row(track)
                    if track.id != shown.last?.id { Divider() }
                }
                if tracks.count > Self.foldedCount {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                    } label: {
                        Label(
                            isExpanded ? "Show fewer" : "Show all \(tracks.count)",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                        .font(.footnote.weight(.semibold))
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal)
        }
    }

    private func row(_ track: Track) -> some View {
        Button { resume(track) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if track.listenedAt != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Listened")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(Self.detail(for: track))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Sep 27, 9:14 PM · stopped at 12:14 / 41:02", or "finished" for one played through.
    static func detail(for track: Track) -> String {
        let when = track.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened) ?? ""
        let length = track.durationMs.map { Scrubber.formatted(Double($0) / 1000) }
        let whereStopped: String
        if isFinished(track) {
            whereStopped = String(localized: "finished")
        } else if let positionMs = track.positionMs, positionMs > 0 {
            let at = Scrubber.formatted(Double(positionMs) / 1000)
            whereStopped = length.map { String(localized: "stopped at \(at) / \($0)") } ?? String(localized: "stopped at \(at)")
        } else {
            whereStopped = String(localized: "not started")
        }
        return [when, whereStopped].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Played to within a few seconds of the end. The player writes the full length there
    /// when an episode ends, so this is what "stopped at the end" looks like.
    static func isFinished(_ track: Track) -> Bool {
        guard let positionMs = track.positionMs, let durationMs = track.durationMs, durationMs > 0 else { return false }
        return positionMs >= durationMs - 5_000
    }

    /// From where it stopped. A finished one starts again from the top — resuming at its
    /// last second would only end it again.
    private func resume(_ track: Track) {
        let engine = PlaybackEngine.shared
        if let positionMs = track.positionMs, positionMs > 0, !Self.isFinished(track) {
            engine.open(track: track, queue: [track], startingAt: Double(positionMs) / 1000)
        } else {
            engine.open(track: track, queue: [track], startingAt: 0)
        }
    }
}
