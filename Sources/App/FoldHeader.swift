import SwiftUI

/// A section heading that opens and shuts what's under it.
///
/// A speaker's page and an album's page are both a metadata form with the thing you came
/// for at the bottom of it: name, bio, language, profile, picture, terms, stats — a
/// screenful of fields to scroll past before the first episode. Shut by default, the page
/// opens on what it's a page *about*, and every field is still one tap away for the day
/// something needs correcting.
///
/// The chevron turns rather than swaps glyphs, so the fold reads as the same control in
/// two states instead of two controls.
struct FoldHeader: View {
    let title: LocalizedStringKey
    @Binding var isOpen: Bool
    /// Said beside the title while shut — what's inside, so a fold isn't a closed door
    /// with nothing written on it.
    var detail: String?

    init(_ title: LocalizedStringKey, isOpen: Binding<Bool>, detail: String? = nil) {
        self.title = title
        _isOpen = isOpen
        self.detail = detail
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                if let detail, !isOpen {
                    Text(detail).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isOpen ? "Hides this section" : "Shows this section")
    }
}
