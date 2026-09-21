import SwiftUI

/// One saved moment, wherever it's listed — Now Playing, an album page, Home. The
/// timestamp is the anchor: a bookmark with nothing typed into it is still useful, so
/// the row never looks empty for want of a note.
struct BookmarkRow: View {
    let bookmark: Bookmark
    /// Shown where the list spans more than one episode.
    var episodeTitle: String?
    /// Whether its note is unfolded below — the pencil says so rather than a second glyph.
    var isOpen = false
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
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

            Button(action: onEdit) {
                Image(systemName: isOpen ? "chevron.down" : "square.and.pencil")
                    .font(.footnote)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .accessibilityLabel("Edit this bookmark")
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
    /// The mark just made, lit until the eye has found it.
    var highlighted: String?
    /// Marking the moment being played. Absent where there is nothing playing to mark —
    /// an album or speaker page collects marks, it doesn't make them.
    var onAdd: (() -> Void)?
    let onPlay: (Bookmark) -> Void
    /// Saved, or deleted — the owner reloads.
    let onChange: () -> Void

    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("NOTES").sectionHeading()
                Spacer()
                if !bookmarks.isEmpty {
                    Text("\(bookmarks.count)").font(.caption).foregroundStyle(.secondary)
                }
                if let onAdd {
                    Button(action: onAdd) {
                        Label("Add bookmark", systemImage: "bookmark.fill").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
            if bookmarks.isEmpty {
                Text("Nothing marked yet. Add a bookmark for the moment you're hearing; the note goes on it afterwards.")
                    .sectionHint()
            } else {
                ForEach(bookmarks) { bookmark in
                    VStack(alignment: .leading, spacing: 10) {
                        BookmarkRow(
                            bookmark: bookmark,
                            episodeTitle: episodeTitle(bookmark),
                            isOpen: expanded == bookmark.id,
                            onPlay: { onPlay(bookmark) },
                            onEdit: { toggle(bookmark) }
                        )
                        if expanded == bookmark.id {
                            BookmarkNoteEditor(
                                bookmark: bookmark,
                                onClose: { expanded = nil },
                                onChange: onChange
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(background(for: bookmark), in: RoundedRectangle(cornerRadius: 10))
                    .id(bookmark.id)
                }
            }
        }
    }

    private func background(for bookmark: Bookmark) -> Color {
        if expanded == bookmark.id { return Color.accentColor.opacity(0.10) }
        return highlighted == bookmark.id ? Color.accentColor.opacity(0.18) : .clear
    }

    private func toggle(_ bookmark: Bookmark) {
        withAnimation(.easeOut(duration: 0.2)) {
            expanded = expanded == bookmark.id ? nil : bookmark.id
        }
    }
}

/// A mark's note, written in the row it belongs to. Under it, what the transcript says at
/// that second — read-only, and read fresh rather than from the copy taken when the mark
/// was made, so it keeps up with corrections and with a transcript that only arrived
/// afterwards.
private struct BookmarkNoteEditor: View {
    let bookmark: Bookmark
    let onClose: () -> Void
    let onChange: () -> Void

    @State private var note: String
    @State private var tags: String
    @State private var spoken: String?
    @FocusState private var isTyping: Bool

    private let store = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(bookmark: Bookmark, onClose: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.bookmark = bookmark
        self.onClose = onClose
        self.onChange = onChange
        _note = State(initialValue: bookmark.note ?? "")
        _tags = State(initialValue: bookmark.tags ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 8) {
                    TextField("Why this moment matters", text: $note, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($isTyping)
                    TextField("Tags, comma separated", text: $tags)
                        .font(.footnote)
                }
                .padding(8)
                .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.35)) }

                Button(action: save) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .buttonStyle(.plain)

            if let spoken, !spoken.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AT THIS MOMENT").sectionHeading()
                    Text(spoken).font(.footnote).foregroundStyle(.tertiary)
                }
            }

            Button("Delete bookmark", role: .destructive, action: delete)
                .font(.caption)
        }
        .onAppear {
            isTyping = true
            spoken = Self.transcriptLine(for: bookmark)
        }
    }

    /// What the stored transcript says at the mark's second, if anything does yet.
    private static func transcriptLine(for bookmark: Bookmark) -> String? {
        let segments = (try? TranscriptStore(dbQueue: DatabaseManager.shared.dbQueue)
            .find(trackID: bookmark.trackID)) ?? []
        let covering = segments.last {
            !$0.text.isEmpty && $0.start <= bookmark.position + 0.5
        }
        return covering?.text ?? bookmark.transcriptText
    }

    private func save() {
        var updated = bookmark
        updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        updated.tags = Bookmark.tagString(tags.split(separator: ",").map(String.init))
        try? store.update(updated)
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        onChange()
        onClose()
    }

    private func delete() {
        try? store.delete(id: bookmark.id)
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
        onChange()
        onClose()
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
