import SwiftUI

/// One saved moment, wherever it's listed — Now Playing, an album page, Home. The
/// timestamp is the anchor: a bookmark with nothing typed into it is still useful, so
/// the row never looks empty for want of a note.
struct BookmarkRow: View {
    let bookmark: Bookmark
    /// Shown where the list spans more than one episode.
    var episodeTitle: String?
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
                Image(systemName: "square.and.pencil")
                    .font(.footnote)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Edit this bookmark")
        }
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
