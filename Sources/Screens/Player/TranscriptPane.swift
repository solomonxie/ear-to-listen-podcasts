import SwiftUI

/// Lyric-style transcript: the line being spoken is the only bright one, it scrolls
/// itself, tapping a line plays from there and reads along, and the pencil beside it
/// corrects the text.
///
/// Two buttons above it, one per recogniser: each transcribes the whole episode in the
/// background and the text arrives all at once when it's done. Nothing is shown while a
/// pass runs but a percentage — text that rewrites itself under the reader was worse than
/// waiting for it.
struct TranscriptPane: View {
    @ObservedObject var transcript = TranscriptRunner.shared
    let currentTime: TimeInterval
    /// The whole player page scrolls as one, so the lyric list doesn't own a scroller —
    /// it drives the page's, which is what lets the artwork scroll away as lines advance.
    let scrollProxy: ScrollViewProxy
    /// Off until asked for, and turned off again by the page the moment the reader
    /// scrolls by hand. Auto-scroll pulling the text back mid-sentence — or away from the
    /// transport you were reaching for — is worse than no auto-scroll at all.
    @Binding var isFollowing: Bool
    /// Asks the page to scroll to the line being spoken and follow from there. The page
    /// owns the scroller, so it owns the jump.
    let onFollow: () -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var editing: TranscriptSegment?
    @State private var showingEdits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
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
    }

    /// One button per recogniser, and nothing else. Each one transcribes the whole
    /// episode; the one that's running says so and stops when pressed again. Which
    /// recogniser to use is the only real choice here — free and on this phone, or more
    /// accurate and charged for — so it's two buttons rather than a switch, a picker and
    /// a mode to understand first.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRANSCRIPT").sectionHeading()
                Spacer()
                if !transcript.edits.isEmpty {
                    Button("\(transcript.edits.count) edit\(transcript.edits.count == 1 ? "" : "s")") { showingEdits = true }
                        .font(.caption)
                }
            }

            HStack(spacing: 10) {
                ForEach(TranscriptionEngineKind.allCases, id: \.self) { engine in
                    engineButton(engine)
                }

                TranscriptControlButton(
                    title: isFollowing ? "Following" : "Follow",
                    systemImage: isFollowing ? "location.fill" : "location",
                    isOn: isFollowing
                ) { onFollow() }
                    .disabled(isFollowing || transcript.lines.isEmpty)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal)
    }

    private func engineButton(_ engine: TranscriptionEngineKind) -> some View {
        let isRunningThis = transcript.runningEngine == engine
        return TranscriptControlButton(
            title: title(for: engine),
            systemImage: isRunningThis ? "stop.fill" : engine.symbolName,
            isOn: isRunningThis
        ) {
            transcript.run(engine: engine)
        }
        // The other recogniser waits its turn: two passes over the same audio at once is
        // twice the battery for one transcript.
        .disabled(transcript.track == nil || (transcript.isRunning && !isRunningThis))
    }

    private func title(for engine: TranscriptionEngineKind) -> LocalizedStringKey {
        if transcript.runningEngine == engine { return "Stop" }
        switch engine {
        case .onDevice: return "On-device"
        case .openAIWhisper: return "AI"
        }
    }

    private var status: LocalizedStringKey? {
        if transcript.isRunning {
            // The whole of what's said while a pass runs. There is nothing else worth
            // saying: it is working through the episode and it will be done when it's done.
            return "Transcribing the whole episode · \(percent)"
        }
        if transcript.lines.isEmpty { return nil }
        // Nothing was spent making this one — it was already in the bucket.
        if transcript.isFromSidecar { return "From a transcript file beside the episode" }
        return transcript.isComplete ? "Whole episode transcribed" : "\(coverage) transcribed"
    }

    static func languageName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier(.bcp47)
    }

    private var percent: String {
        transcript.progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var coverage: String {
        transcript.coverageFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private var emptyStateDetail: LocalizedStringKey {
        if transcript.isRunning {
            return "Working through the episode — \(percent) done. The whole transcript appears here at once when it's finished."
        }
        return "Nothing transcribed yet. On-device costs battery and no money; AI is more accurate, needs a key, and sends the audio to the vendor. Either one does the whole episode in the background. A transcript file sitting beside the episode is used instead when there is one."
    }

    /// Tapping a line is "read along from here", not just "seek here" — it jumps
    /// playback to the line and hands the page back to the transcript, which is what
    /// everyone reaches for next anyway.
    private func play(from segment: TranscriptSegment) {
        onSeek(segment.start)
        isFollowing = true
    }

    @ViewBuilder private var lines: some View {
        if transcript.lines.isEmpty {
            ContentUnavailableView {
                Label("No transcript yet", systemImage: "text.bubble")
            } description: {
                Text(emptyStateDetail)
            }
            // Inside the page's scroller it would otherwise collapse to nothing.
            .frame(minHeight: 220)
        } else {
            // Looked up once for the whole list, not once per row: while a transcription
            // is running this list is rebuilt several times a second, and "am I the line
            // being spoken?" asked per row was the difference between a page that scrolls
            // and a page that stutters.
            let spokenStart = transcript.currentLine(at: currentTime)?.start
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcript.lines) { segment in
                    TranscriptLine(
                        segment: segment,
                        isCurrent: segment.start == spokenStart,
                        onPlay: { play(from: segment) },
                        onEdit: { editing = segment }
                    )
                    // Nothing but the text, the highlight and the "still being revised"
                    // flag can change a row, so a redraw of the list leaves settled rows
                    // alone instead of rebuilding hundreds of them.
                    .equatable()
                    .id(segment.start)
                }
            }
            .padding(.horizontal)
            .onChange(of: transcript.currentLine(at: currentTime)?.start) { _, start in
                guard isFollowing, let start else { return }
                withAnimation(.easeOut(duration: 0.25)) { scrollProxy.scrollTo(start, anchor: .center) }
            }
        }
    }
}

private struct TranscriptLine: View, Equatable {
    /// Closures are left out of the comparison on purpose: they only ever capture this
    /// row's own segment and the pane's state, both of which survive a skipped redraw.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment && lhs.isCurrent == rhs.isCurrent
    }

    let segment: TranscriptSegment
    let isCurrent: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
            // Tapping a lyric plays from it — that's what the timestamps are for, and it's
            // the thing you want while listening. Correcting is the deliberate act, so it
            // gets its own small target.
            .onTapGesture(perform: onPlay)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.footnote)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Correct this line")
        }
        .contextMenu {
            Button("Play from here", systemImage: "play.fill", action: onPlay)
            Button("Correct this line", systemImage: "pencil", action: onEdit)
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

/// One of the three transcript buttons: an icon that lights up when its state is on, with
/// the word under it. Sized like a transport control rather than a list row — they sit
/// above a page of text and get tapped mid-listen.
private struct TranscriptControlButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.subheadline)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 72)
            .padding(.vertical, 8)
            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.ultraThinMaterial),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn ? Color.accentColor.opacity(0.5) : .clear))
            .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
