import SwiftUI

/// Lyric-style transcript: the line being spoken is the only bright one, it scrolls
/// itself, and tapping any line opens it for correction. Whether a recognizer is running
/// at all — and which one — is one control, since "off / free & offline / paid & better"
/// is a single choice, not two.
struct TranscriptPane: View {
    @ObservedObject var transcript = LiveTranscript.shared
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var editing: TranscriptSegment?
    @State private var showingEdits = false
    @State private var confirmingReload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let status {
                Text(status).sectionRowSecondary().padding(.horizontal)
            }
            if let lastError = transcript.lastError {
                Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
            }
            lines
        }
        .sheet(item: $editing) { segment in
            TranscriptLineEditor(segment: segment) { transcript.applyEdit(to: segment, newText: $0) }
        }
        .sheet(isPresented: $showingEdits) {
            TranscriptEditsView(edits: transcript.edits)
        }
        .confirmationDialog("Transcribe this episode again?", isPresented: $confirmingReload, titleVisibility: .visible) {
            Button("Re-transcribe everything", role: .destructive) { transcript.forceReload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Throws away the stored transcript and starts over. Your corrections are kept — they're used as hints for the new pass.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Transcribe", selection: engineSelection) {
                    Text("Off").tag(TranscriptionEngineKind?.none)
                    ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(TranscriptionEngineKind?.some(kind))
                    }
                }
                Divider()
                Button("Transcribe again…", systemImage: "arrow.clockwise") { confirmingReload = true }
                    .disabled(transcript.track == nil)
            } label: {
                Label(menuTitle, systemImage: "waveform")
                    .font(.footnote.weight(.semibold))
            }

            Spacer()

            if !transcript.edits.isEmpty {
                Button("\(transcript.edits.count) edit\(transcript.edits.count == 1 ? "" : "s")") { showingEdits = true }
                    .font(.caption)
            }
        }
        .padding(.horizontal)
    }

    private var status: String? {
        if let window = transcript.activeWindow {
            return "Transcribing \(Scrubber.formatted(window.start))–\(Scrubber.formatted(window.end))… · \(percent) done"
        }
        if transcript.lines.isEmpty { return nil }
        return transcript.isComplete ? "Whole episode transcribed" : "\(percent) transcribed"
    }

    private var percent: String {
        (transcript.coverageFraction).formatted(.percent.precision(.fractionLength(0)))
    }

    private var menuTitle: String {
        transcript.isLiveEnabled ? transcript.engineKind.displayName : "Transcribe: Off"
    }

    private var engineSelection: Binding<TranscriptionEngineKind?> {
        Binding(
            get: { transcript.isLiveEnabled ? transcript.engineKind : nil },
            set: { kind in
                guard let kind else {
                    transcript.isLiveEnabled = false
                    return
                }
                transcript.engineKind = kind
                transcript.isLiveEnabled = true
            }
        )
    }

    @ViewBuilder private var lines: some View {
        if transcript.lines.isEmpty {
            ContentUnavailableView {
                Label("No transcript yet", systemImage: "text.bubble")
            } description: {
                Text(transcript.isLiveEnabled
                     ? "Listening ahead — lines appear as they're recognised."
                     : "Pick a recogniser above to transcribe as you listen. Whatever gets done is saved, so you can stop and come back.")
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(transcript.lines) { segment in
                            TranscriptLine(
                                segment: segment,
                                isCurrent: segment.start == transcript.currentLine(at: currentTime)?.start,
                                onTap: { editing = segment },
                                onPlay: { onSeek(segment.start) }
                            )
                            .id(segment.start)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
                .onChange(of: transcript.currentLine(at: currentTime)?.start) { _, start in
                    guard let start else { return }
                    withAnimation { proxy.scrollTo(start, anchor: .center) }
                }
            }
        }
    }
}

private struct TranscriptLine: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let onTap: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.text)
                .font(isCurrent ? .body.weight(.semibold) : .body)
                .foregroundStyle(isCurrent ? .primary : .secondary)
            HStack(spacing: 6) {
                Text(Scrubber.formatted(segment.start))
                if segment.isEdited {
                    Label("edited", systemImage: "pencil").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption2)
            .foregroundStyle(isCurrent ? .secondary : .tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Tap corrects, because that's the one thing only a human can do here; jumping
        // playback to a line is on the context menu next to it.
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Play from here", systemImage: "play.fill", action: onPlay)
            Button("Correct this line", systemImage: "pencil", action: onTap)
        }
    }
}

private struct TranscriptLineEditor: View {
    let segment: TranscriptSegment
    let onSave: (String) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(segment: TranscriptSegment, onSave: @escaping (String) -> Void) {
        self.segment = segment
        self.onSave = onSave
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("At \(Scrubber.formatted(segment.start))").sectionRowSecondary()
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Text("Saved on this device, and used as a hint for the rest of the episode — names and terms you fix once stop coming back wrong.")
                    .sectionHint()
                Spacer()
            }
            .padding()
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Correct line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The edit history, kept so a correction is reviewable rather than just applied — and so
/// it's obvious what the recogniser keeps getting wrong.
private struct TranscriptEditsView: View {
    let edits: [TranscriptEdit]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if edits.isEmpty {
                    ContentUnavailableView("No corrections yet", systemImage: "pencil")
                } else {
                    List(edits) { edit in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("At \(Scrubber.formatted(edit.segmentStart))")
                                Spacer()
                                Text(edit.createdAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            .sectionRowSecondary()
                            diff(edit)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("My corrections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func diff(_ edit: TranscriptEdit) -> Text {
        WordDiff.tokens(from: edit.originalText, to: edit.editedText).reduce(Text("")) { partial, token in
            partial + styled(token) + Text(" ")
        }
        .font(.footnote)
    }

    private func styled(_ token: WordDiff.Token) -> Text {
        switch token.kind {
        case .same: return Text(token.text).foregroundColor(.secondary)
        case .removed: return Text(token.text).foregroundColor(.red).strikethrough()
        case .added: return Text(token.text).foregroundColor(.green)
        }
    }
}
