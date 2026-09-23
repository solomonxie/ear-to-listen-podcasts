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

/// The episode page's terms: the same chips, plus a `＋` that unfolds a field to add one
/// by hand and whatever the caller hangs off each chip to remove it.
///
/// **Added, deleted, never edited.** A term is a word said in the recording — renaming it
/// makes it a word nobody said, and the count under it stops meaning anything. Wrong term:
/// delete it and add the right one, which is two taps and leaves the counting honest.
///
/// The count of a hand-added term is still counted in the transcript, not typed: a number
/// someone entered is the one number on this page that couldn't be checked against
/// anything.
struct TermsField<Chip: View>: View {
    let terms: [TermCount]
    /// Shares the card's one-open-control-at-a-time state, like `TagField` does.
    @Binding var open: String?
    let onAdd: (String) -> Void
    @ViewBuilder var chip: (TermCount) -> Chip

    @State private var newTerm = ""
    @FocusState private var isTyping: Bool

    private var isOpen: Bool { open == "terms" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(terms) { term in
                    chip(term)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { open = isOpen ? nil : "terms" }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            if isOpen {
                HStack {
                    TextField("A name or term", text: $newTerm)
                        .font(.footnote)
                        .focused($isTyping)
                        .submitLabel(.done)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .onAppear { isTyping = true }
            }
        }
    }

    private func commit() {
        let name = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        newTerm = ""
        guard !name.isEmpty else { return }
        onAdd(name)
        withAnimation(.easeOut(duration: 0.18)) { open = nil }
    }
}
