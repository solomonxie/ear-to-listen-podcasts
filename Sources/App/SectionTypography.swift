import SwiftUI

/// One type scale for the section-style screens (Remote, Settings), so a group's heading
/// is never smaller than the rows underneath it. Four roles, nothing else:
///
///     sectionTitle    .title3.bold   "Settings"        — top of a whole section
///     sectionRow      .subheadline   "Add a Folder"    — any row or tappable label
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
