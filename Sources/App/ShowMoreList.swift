import SwiftUI

/// The first few rows of a long list, with the rest behind one tap.
///
/// A folder of three hundred episodes listed whole is a page nobody reaches the bottom
/// of, and everything under it — the next section, the one after — is unreachable in
/// practice. Three is enough to show what the list *is*; the count on the button says how
/// much more there is, which a cut-off list otherwise hides.
///
/// Only what's shown is folded away. Whatever the rows do — playing an episode queues the
/// whole collection — still works off the full list the caller passed in.
struct ShowMoreList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var limit: Int = 3
    @ViewBuilder let row: (Item) -> Row

    @State private var isExpanded = false

    private var shown: [Item] { isExpanded ? items : Array(items.prefix(limit)) }

    var body: some View {
        ForEach(shown) { row($0) }
        if items.count > limit {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                Label(
                    isExpanded ? "Show fewer" : "Show all \(items.count)",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(.footnote.weight(.semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}
