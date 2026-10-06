import SwiftUI

/// The one big action under an album's or speaker's hero: pick up the episode left
/// half-way, or start the first one not yet heard. The whole list is the queue.
struct ContinuePlayButton: View {
    let tracks: [Track]

    /// Pages list episodes whose audio is gone too; there's nothing to start there.
    private var playable: [Track] { tracks.filter { !$0.isLost } }

    private var target: (track: Track, label: LocalizedStringKey)? {
        let tracks = playable
        let unfinished = tracks
            .filter { $0.listenedAt == nil && ($0.positionMs ?? 0) > 2_000 && $0.lastPlayedAt != nil }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
        if let unfinished { return (unfinished, "Continue · \(unfinished.title)") }
        if let next = tracks.first(where: { $0.listenedAt == nil }) {
            return (next, tracks.contains { $0.listenedAt != nil } ? "Play next · \(next.title)" : "Play")
        }
        return tracks.first.map { ($0, "Play again") }
    }

    var body: some View {
        if let target {
            Button {
                PlaybackEngine.shared.open(track: target.track, queue: playable)
            } label: {
                Label(target.label, systemImage: "play.fill")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .listRowSeparator(.hidden)
        }
    }
}

/// A list section that starts folded: its header is the switch, and says how many rows
/// are behind it.
struct FoldedSection<Content: View>: View {
    let title: LocalizedStringKey
    let count: Int
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        Section {
            if isExpanded { content() }
        } header: {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                    Text("\(count)").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.footnote.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
