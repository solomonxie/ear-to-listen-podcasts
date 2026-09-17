import SwiftUI

/// One type scale for the section-style screens (Remote, Settings), so a group's heading
/// is never smaller than the rows underneath it. Four roles, nothing else:
///
///     sectionTitle    .title3.bold   "Settings"        — top of a whole section
///     sectionRow      .subheadline   "Sync Now"        — any row or tappable label
///     sectionHint     .footnote      explanatory text under a heading/group
///     sectionHeading  .caption       "LOCAL FOLDERS"   — a group inside a section
///
/// Rows are the default: apply `.sectionRow()` once to a section's outermost container and
/// every label inside inherits it, leaving only the headings and hints to opt out. Left to
/// SwiftUI's own default a label renders at `.body` (17pt) — larger than the 12pt heading
/// above it, which is what made these screens read as randomly sized.
extension View {
    func sectionTitle() -> some View {
        font(.title3.bold())
    }

    func sectionHeading() -> some View {
        font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    func sectionRow() -> some View {
        font(.subheadline)
    }

    /// A row's trailing/secondary value — the usage count, a path, Active/Inactive.
    func sectionRowSecondary() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }

    func sectionHint() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }
}

/// The long explanation a group sometimes needs, folded into an ⓘ beside its heading.
///
/// A paragraph under every heading turns a settings page into an essay nobody reads, and
/// it pushes the controls — the reason anyone came — below the fold. What stays outside is
/// at most one sentence, usually the current state; the reasoning, the caveats and the
/// "never your keys" promises live one tap away, where they're still there for whoever
/// wants them.
struct SectionInfo: View {
    let text: LocalizedStringKey

    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing) {
            Text(text)
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .padding(16)
                .frame(maxWidth: 320)
                // Without this a popover on iPhone becomes a sheet, which is far too much
                // ceremony for two sentences of explanation.
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A group heading and its ⓘ, since they always travel together.
struct SectionHeading: View {
    let title: LocalizedStringKey
    var info: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).sectionHeading()
            if let info { SectionInfo(text: info) }
        }
    }
}
