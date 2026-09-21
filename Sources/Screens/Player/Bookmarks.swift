import SwiftUI

/// One saved moment, wherever it's listed — Now Playing, an album page, Home. The
/// timestamp is the anchor: a bookmark with nothing typed into it is still useful, so
/// the row never looks empty for want of a note.
///
/// **The row opens the note in a sheet; the play glyph at its end jumps to the moment.**
/// Reading and
/// writing what a mark says is what a list of marks is scrolled for, and that's the whole
/// row. Jumping the player is the sharper action and the rarer one, so it gets a target
/// of its own rather than the whole row — and a mistap costs an unfolded note instead of
/// losing your place in what's playing.
struct BookmarkRow: View {
    let bookmark: Bookmark
    /// Shown where the list spans more than one episode.
    var episodeTitle: String?
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: 10) {
                    Text(Scrubber.formatted(bookmark.position))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                    VStack(alignment: .leading, spacing: 4) {
                        if let episodeTitle {
                            Text(episodeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let note = bookmark.note, !note.isEmpty {
                            Text(note).font(.footnote)
                        }
                        if let spoken = bookmark.transcriptText, !spoken.isEmpty {
                            Text(spoken)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if bookmark.note == nil, bookmark.transcriptText == nil, bookmark.tagList.isEmpty {
                            Text("Saved moment").font(.footnote).foregroundStyle(.tertiary)
                        }
                        if !bookmark.tagList.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(bookmark.tagList, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onPlay) {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("Play from this moment")
        }
    }
}

/// The notes made inside an episode — which is what a bookmark becomes once something is
/// typed into it. Used on the episode page for one episode's marks, and on album and
/// speaker pages for every mark made across theirs.
///
/// A mark with nothing typed in it is still a note: the timestamp is the note. Marking is
/// one tap here and asks nothing — a dialog over the thing you're listening to is how a
/// mark gets made too late — and the note is written afterwards, in the row itself.
struct NotesPane: View {
    let bookmarks: [Bookmark]
    /// Shown per row where the list spans more than one episode.
    var episodeTitle: (Bookmark) -> String? = { _ in nil }
    /// Folds the marks under the episode each came from, closed to start, the way Home's
    /// bookmark shelf does. A page that collects every mark across an album or a speaker
    /// is a wall of rows flat; folded, it says which episodes were worth marking and
    /// opens only the one meant. An episode's own page has one episode and stays flat.
    var foldsByEpisode = false
    /// The mark just made, lit until the eye has found it.
    var highlighted: String?
    /// Marking the moment being played. Absent where there is nothing playing to mark —
    /// an album or speaker page collects marks, it doesn't make them.
    var onAdd: (() -> Void)?
    let onPlay: (Bookmark) -> Void
    /// Saved, or deleted — the owner reloads.
    let onChange: () -> Void

    /// The mark whose editor is up. A sheet rather than a row that unfolds: the editor is
    /// a keyboard's worth of fields, so unfolding it pushed the list around and made the
    /// pane scroll itself to keep the field in view — a page that moves under you while
    /// you reach for it. A sheet leaves the list exactly where it was.
    @State private var editing: Bookmark?
    @State private var openEpisodes: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOTES").sectionHeading()
                Spacer()
                if !bookmarks.isEmpty {
                    Text(countLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            if bookmarks.isEmpty {
                Text("Nothing marked yet. Mark the moment first — the note goes on it afterwards.")
                    .sectionHint()
            } else if foldsByEpisode {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(folds) { fold in
                        episodeFold(fold)
                        if fold.id != folds.last?.id { Divider() }
                    }
                }
            } else {
                ForEach(bookmarks) { markCard($0, episodeTitle: episodeTitle($0)) }
            }
            // Under the marks rather than beside the heading: it says what it marks —
            // where you are right now — and the end of the list is where the one it's
            // about to make will appear.
            if let onAdd {
                Button(action: onAdd) {
                    Label("Add a bookmark at current time", systemImage: "bookmark.fill")
                        .font(.footnote.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
            }
        }
        .sheet(item: $editing, onDismiss: onChange) { bookmark in
            BookmarkEditorView(bookmark: bookmark, episodeTitle: episodeTitle(bookmark))
        }
    }

    private var countLabel: String {
        guard foldsByEpisode else { return "\(bookmarks.count)" }
        return "\(bookmarks.count) in \(folds.count) episode\(folds.count == 1 ? "" : "s")"
    }

    /// One episode's marks: a tappable line saying which episode and how many, and the
    /// marks themselves once it's open.
    @ViewBuilder
    private func episodeFold(_ fold: EpisodeFold) -> some View {
        let isOpen = openEpisodes.contains(fold.id)
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                if isOpen { openEpisodes.remove(fold.id) } else { openEpisodes.insert(fold.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(fold.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("(\(fold.bookmarks.count))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            // No episode title on the rows: the line they are folded under just said it.
            ForEach(fold.bookmarks) { markCard($0, episodeTitle: nil) }
        }
    }

    private func markCard(_ bookmark: Bookmark, episodeTitle: String?) -> some View {
        BookmarkRow(
            bookmark: bookmark,
            episodeTitle: episodeTitle,
            onPlay: { onPlay(bookmark) },
            onEdit: { editing = bookmark }
        )
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(background(for: bookmark), in: RoundedRectangle(cornerRadius: 10))
        .id(bookmark.id)
    }

    /// Episodes in the order they were last marked — the top of the list is the one just
    /// left — and the marks inside each in the order they occur, since a list of moments
    /// that jumps around its own timeline can't be read.
    private var folds: [EpisodeFold] {
        var order: [String] = []
        var byTrack: [String: [Bookmark]] = [:]
        for bookmark in bookmarks {
            if byTrack[bookmark.trackID] == nil { order.append(bookmark.trackID) }
            byTrack[bookmark.trackID, default: []].append(bookmark)
        }
        return order.compactMap { trackID in
            guard let marks = byTrack[trackID], let first = marks.first else { return nil }
            return EpisodeFold(
                id: trackID,
                title: episodeTitle(first) ?? "Unknown episode",
                bookmarks: marks.sorted { $0.positionMs < $1.positionMs }
            )
        }
    }

    private struct EpisodeFold: Identifiable {
        let id: String
        let title: String
        let bookmarks: [Bookmark]
    }

    private func background(for bookmark: Bookmark) -> Color {
        highlighted == bookmark.id ? Color.accentColor.opacity(0.18) : .clear
    }
}

/// Everything a bookmark can carry, typed after the fact — a note, tags, and the words
/// that were being spoken. The transcript line is a copy taken when the mark was made,
/// so re-transcribing the episode can't rewrite what you marked, and it's editable for
/// the same reason a transcript line is: the recogniser gets names wrong.
struct BookmarkEditorView: View {
    let bookmark: Bookmark
    /// Named here because the sheet can be opened from a list spanning many episodes.
    var episodeTitle: String?

    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var tags: String
    @State private var transcriptText: String

    private let store = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(bookmark: Bookmark, episodeTitle: String? = nil) {
        self.bookmark = bookmark
        self.episodeTitle = episodeTitle
        _note = State(initialValue: bookmark.note ?? "")
        _tags = State(initialValue: bookmark.tags ?? "")
        _transcriptText = State(initialValue: bookmark.transcriptText ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("At", value: Scrubber.formatted(bookmark.position))
                    if let episodeTitle {
                        LabeledContent("Episode", value: episodeTitle)
                    }
                    LabeledContent("Saved", value: bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.footnote)

                Section("Note") {
                    TextField("Why this moment matters", text: $note, axis: .vertical)
                        .lineLimit(3...)
                }

                Section {
                    TextField("Comma separated", text: $tags)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Your own words for finding this again — \u{201C}quote\u{201D}, \u{201C}to check\u{201D}, a person's name.")
                }

                Section {
                    TextField("What was said here", text: $transcriptText, axis: .vertical)
                        .lineLimit(2...10)
                } header: {
                    Text("Transcript")
                } footer: {
                    Text("Copied from the transcript when the mark was made. Correcting it here changes the bookmark only.")
                }

                Section {
                    Button("Delete Bookmark", role: .destructive) { delete() }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        var updated = bookmark
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.tags = Bookmark.tagString(tags.split(separator: ",").map(String.init))
        updated.transcriptText = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        try? store.update(updated)
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        dismiss()
    }

    private func delete() {
        try? store.delete(id: bookmark.id)
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        dismiss()
    }
}
