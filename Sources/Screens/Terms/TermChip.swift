import SwiftUI

/// One term, with how often it's said. The count is the point — a term list without it is
/// a tag cloud, and the whole reason these are extracted rather than typed is that they
/// can be counted.
struct TermChip: View {
    let term: TermCount

    var body: some View {
        HStack(spacing: 5) {
            Text(term.name)
                .font(.caption2)
                .lineLimit(1)
            Text("\(term.mentions)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
    }
}

/// Terms as chips, biggest first — the episode page's and the album page's shape. The
/// chips wrap rather than scroll sideways: there are a couple of dozen of them and the
/// ones past the fold of a sideways row are the ones nobody ever sees.
struct TermChips<Chip: View>: View {
    let terms: [TermCount]
    /// Each screen wraps the chip in its own link — the player pushes through
    /// `PlayerRoute`, everything else pushes a view.
    @ViewBuilder var chip: (TermCount) -> Chip

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(terms) { term in
                chip(term)
            }
        }
    }
}
