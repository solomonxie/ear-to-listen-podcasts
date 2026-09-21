import SwiftUI

/// Saved moments on Home, grouped under the episode they came from and **folded by
/// default**.
///
/// Home is a page of shelves you scroll past, not a place to read a hundred marks. So a
/// group shows its episode and how many marks are in it — `(10)` — and opens only when
/// asked. Both ends are capped: a few episodes here, a few marks inside each one, and a
/// way through to the full list for anything past that. An unbounded list on a page made
/// of shelves pushes everything below it out of reach.
struct BookmarksSection: View {
    let groups: [BookmarkGroup]
    let onPlay: (Track, Bookmark) -> Void
    let onEdit: (Bookmark) -> Void

    @State private var expanded: Set<String> = []

    /// Enough to show what the section is; past this, the full page is the better place.
    private static let episodeLimit = 4
    private static let markLimit = 5

    private var shown: [BookmarkGroup] { Array(groups.prefix(Self.episodeLimit)) }
    private var totalCount: Int { groups.reduce(0) { $0 + $1.bookmarks.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bookmarks").font(.title3.bold())
                Spacer()
                if groups.count > Self.episodeLimit {
                    NavigationLink {
                        BookmarksView(onPlay: onPlay, onEdit: onEdit)
                    } label: {
                        Text("See all \(totalCount)").font(.subheadline)
                    }
                } else {
                    Text("\(totalCount) in \(groups.count) episode\(groups.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            VStack(spacing: 0) {
                ForEach(shown) { group in
                    BookmarkGroupRow(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        markLimit: Self.markLimit,
                        onToggle: { toggle(group.id) },
                        onPlay: onPlay,
                        onEdit: onEdit,
                        overflow: {
                            AnyView(
                                NavigationLink {
                                    BookmarksView(onPlay: onPlay, onEdit: onEdit)
                                } label: {
                                    Text("Show").font(.caption)
                                }
                            )
                        }
                    )
                    if group.id != shown.last?.id { Divider() }
                }
            }
            .padding(.horizontal)
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

/// Every saved moment, same folding, no caps — the page behind "See all".
///
/// Loads its own rows rather than taking Home's: Home reads `BookmarkStore.recent`, which
/// stops at 30, so handing that list to a screen called "all" would quietly show a
/// fraction of them. A `List` so rows are built as they're reached.
struct BookmarksView: View {
    let onPlay: (Track, Bookmark) -> Void
    let onEdit: (Bookmark) -> Void

    @State private var groups: [BookmarkGroup] = []
    @State private var expanded: Set<String> = []

    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        List {
            ForEach(groups) { group in
                BookmarkGroupRow(
                    group: group,
                    isExpanded: expanded.contains(group.id),
                    markLimit: nil,
                    onToggle: { toggle(group.id) },
                    onPlay: onPlay,
                    onEdit: onEdit,
                    overflow: { AnyView(EmptyView()) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No bookmarks", systemImage: "bookmark",
                    description: Text("Tap the bookmark button while listening to keep a moment.")
                )
            }
        }
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in load() }
    }

    private func load() {
        let tracks = (try? trackStore.all()) ?? []
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        groups = BookmarkGroup.group((try? bookmarkStore.all()) ?? []) { byID[$0] }
    }

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.18)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }
}

/// One episode's marks: a tappable header that says how many, and the marks themselves
/// once it's open.
private struct BookmarkGroupRow: View {
    let group: BookmarkGroup
    let isExpanded: Bool
    /// Nil means show them all — the full page has the room.
    let markLimit: Int?
    let onToggle: () -> Void
    let onPlay: (Track, Bookmark) -> Void
    let onEdit: (Bookmark) -> Void
    let overflow: () -> AnyView

    private var visible: [Bookmark] {
        guard let markLimit else { return group.bookmarks }
        return Array(group.bookmarks.prefix(markLimit))
    }

    private var hidden: Int { group.bookmarks.count - visible.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(group.track.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text("(\(group.bookmarks.count))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, bookmark in
                    row(bookmark, number: index + 1)
                    if index < visible.count - 1 { Divider().padding(.leading, 34) }
                }
                if hidden > 0 {
                    HStack {
                        Text("+\(hidden) more").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        overflow()
                    }
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func row(_ bookmark: Bookmark, number: Int) -> some View {
        // The row reads and edits the note; the glyph at its end jumps the player. Same
        // division as `BookmarkRow`, for the same reason.
        Button {
            onEdit(bookmark)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // The ordinal within its episode, not a global one — it's what makes a
                // mark referable at all, and it's stable as long as the episode is.
                Text("\(number)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Scrubber.formatted(bookmark.position))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        ForEach(bookmark.tagList, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    // A mark with nothing typed into it is still a useful mark, so the row
                    // never looks broken for want of a note.
                    Text(bookmark.note ?? bookmark.transcriptText ?? "Saved moment")
                        .font(.footnote)
                        .foregroundStyle(bookmark.note == nil && bookmark.transcriptText == nil ? .tertiary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button { onPlay(group.track, bookmark) } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play from this moment")
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One episode's saved moments, in the order they occur in it.
struct BookmarkGroup: Identifiable {
    let track: Track
    let bookmarks: [Bookmark]

    var id: String { track.id }

    /// Groups newest-first bookmarks by episode. The episodes stay in "most recently
    /// marked" order — that's what makes the top of the list the one you were just in —
    /// while the marks *within* an episode go by position, since a numbered list that
    /// jumps around its own timeline can't be read.
    static func group(_ bookmarks: [Bookmark], track: (String) -> Track?) -> [BookmarkGroup] {
        var order: [String] = []
        var byTrack: [String: [Bookmark]] = [:]
        for bookmark in bookmarks {
            if byTrack[bookmark.trackID] == nil { order.append(bookmark.trackID) }
            byTrack[bookmark.trackID, default: []].append(bookmark)
        }
        return order.compactMap { trackID in
            guard let track = track(trackID), let marks = byTrack[trackID] else { return nil }
            return BookmarkGroup(track: track, bookmarks: marks.sorted { $0.positionMs < $1.positionMs })
        }
    }
}
