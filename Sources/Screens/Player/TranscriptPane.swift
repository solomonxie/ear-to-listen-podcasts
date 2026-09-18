import SwiftUI

/// Lyric-style transcript: the line being spoken is the only bright one, it scrolls
/// itself, tapping a line plays from there and reads along, and the pencil beside it
/// corrects the text.
///
/// The controls sit flat above the lines rather than inside a menu — three buttons whose
/// look is their state, since a menu made each one a tap-and-hunt and hid whether
/// anything was running at all.
struct TranscriptPane: View {
    @ObservedObject var transcript = LiveTranscript.shared
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
    @State private var confirmingReload = false

    /// Constant on purpose — see `VolatileTail`.
    private static let volatileRowID = "transcript.volatile"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if let status {
                Text(status).sectionRowSecondary().padding(.horizontal)
            }
            if let lastError = transcript.lastError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lastError).font(.footnote).foregroundStyle(.orange)
                    Button("Try again") { transcript.retry() }.font(.footnote)
                }
                .padding(.horizontal)
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

    /// Three buttons and a recogniser, in view and in a fixed place. Icons rather than a
    /// column of rows: these are reached for mid-listen, they sit above a page of text,
    /// and each one is a state you need to see at a glance — on, running ahead, following.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRANSCRIPT").sectionHeading()
                Spacer()
                if !transcript.edits.isEmpty {
                    Button("\(transcript.edits.count) edit\(transcript.edits.count == 1 ? "" : "s")") { showingEdits = true }
                        .font(.caption)
                }
                Button("Transcribe again…") { confirmingReload = true }
                    .font(.caption)
                    .disabled(transcript.track == nil)
            }

            HStack(spacing: 10) {
                // The captions button everyone already knows, doing what it looks like:
                // turning the words on for this episode. Deliberately forgotten when the
                // next episode opens — see `isLiveEnabled`.
                TranscriptControlButton(
                    title: transcript.isLiveEnabled ? "Subtitles on" : "Subtitles",
                    systemImage: transcript.isLiveEnabled ? "captions.bubble.fill" : "captions.bubble",
                    isOn: transcript.isLiveEnabled
                ) { transcript.isLiveEnabled.toggle() }
                    .disabled(transcript.track == nil)

                // Transcribing otherwise follows the episode, so one you walked away from
                // stops costing battery. This is how you ask for the rest of it now — and
                // the same button is how you stop it again.
                TranscriptControlButton(
                    title: transcript.isRunningAhead ? "Pause" : (transcript.coverageFraction > 0 ? "Finish all" : "Whole episode"),
                    systemImage: transcript.isRunningAhead ? "pause.fill" : "bolt.fill",
                    isOn: transcript.isRunningAhead
                ) { transcript.toggleWholeEpisode() }
                    .disabled(transcript.track == nil || transcript.isComplete)

                TranscriptControlButton(
                    title: isFollowing ? "Following" : "Follow",
                    systemImage: isFollowing ? "location.fill" : "location",
                    isOn: isFollowing
                ) { onFollow() }
                    .disabled(isFollowing || transcript.lines.isEmpty)

                Spacer(minLength: 0)
            }

            Picker("Recogniser", selection: engineSelection) {
                ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!transcript.isLiveEnabled)
        }
        .padding(.horizontal)
    }

    private var engineSelection: Binding<TranscriptionEngineKind> {
        Binding(get: { transcript.engineKind }, set: { transcript.engineKind = $0 })
    }

    private var status: LocalizedStringKey? {
        if transcript.isWaitingForPlayback {
            return "Paused with the episode · \(percent) transcribed"
        }
        if let window = transcript.activeWindow {
            return "Listening to \(Scrubber.formatted(window.start))–\(Scrubber.formatted(window.end))… · \(percent) done"
        }
        if transcript.lines.isEmpty { return nil }
        // Nothing was spent making this one — it was already in the bucket.
        if transcript.isFromSidecar { return "From a transcript file beside the episode" }
        return transcript.isComplete ? "Whole episode transcribed" : "\(percent) transcribed"
    }

    static func languageName(_ locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier(.bcp47)
    }

    private var percent: String {
        (transcript.coverageFraction).formatted(.percent.precision(.fractionLength(0)))
    }

    /// A window of music or silence transcribes to nothing, so "working" and "nothing to
    /// show yet" are both true at once — say which stretch is being worked on rather than
    /// leave a blank pane that reads as broken.
    private var emptyStateDetail: LocalizedStringKey {
        if let window = transcript.activeWindow {
            return "Working through \(Scrubber.formatted(window.start))–\(Scrubber.formatted(window.end)) — lines appear as they're recognised. Nothing yet means no speech has been made out so far."
        }
        if transcript.isWaitingForPlayback {
            return "Waiting for playback — transcribing follows the episode. Tap \u{201C}Whole episode\u{201D} above to let it run ahead on its own."
        }
        if transcript.isLiveEnabled {
            return "Listening from where you are — lines appear as they're recognised."
        }
        return "Off for this episode — tap Subtitles above to start one. Anything transcribed before, or a transcript file sitting beside the episode, still shows here either way."
    }

    /// Tapping a line is "read along from here", not just "seek here" — it jumps
    /// playback to the line and hands the page back to the transcript, which is what
    /// everyone reaches for next anyway.
    private func play(from segment: TranscriptSegment) {
        onSeek(segment.start)
        isFollowing = true
    }

    @ViewBuilder private var lines: some View {
        if transcript.lines.isEmpty, transcript.volatilePhrases.isEmpty {
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
                        isProvisional: transcript.isProvisional(segment),
                        onPlay: { play(from: segment) },
                        onEdit: { editing = segment }
                    )
                    // Nothing but the text, the highlight and the "still being revised"
                    // flag can change a row, so a redraw of the list leaves settled rows
                    // alone instead of rebuilding hundreds of them.
                    .equatable()
                    .id(segment.start)
                }
                // One view with one identity, however often the words inside it change.
                // Giving each in-flight phrase its own row made the list churn on every
                // revision — several times a second — and nothing would hold still.
                if !transcript.volatilePhrases.isEmpty {
                    VolatileTail(phrases: transcript.volatilePhrases)
                        .equatable()
                        .id(Self.volatileRowID)
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

/// The words the recognizer hasn't finished with. Rendered as one block rather than a row
/// per phrase so it keeps a single identity in the list — it is rewritten several times a
/// second, and anything keyed off its contents would thrash. No timestamps and no tap
/// target, because none of it is settled enough to seek to.
private struct VolatileTail: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.phrases == rhs.phrases }

    let phrases: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(phrases.enumerated()), id: \.offset) { _, phrase in
                Text(phrase)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Label("hearing…", systemImage: "waveform")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.75)
        // Text arriving this fast must not cross-fade, or it reads as flicker.
        .animation(nil, value: phrases)
    }
}

private struct TranscriptLine: View, Equatable {
    /// Closures are left out of the comparison on purpose: they only ever capture this
    /// row's own segment and the pane's state, both of which survive a skipped redraw.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment && lhs.isCurrent == rhs.isCurrent && lhs.isProvisional == rhs.isProvisional
    }

    let segment: TranscriptSegment
    let isCurrent: Bool
    /// Still being revised by the engine — shown so text arrives as it's heard, but not
    /// correctable, since there's nothing stored yet for an edit to attach to.
    let isProvisional: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(segment.text)
                    .font(isCurrent ? .body.weight(.semibold) : .body)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .opacity(isProvisional ? 0.6 : 1)
                HStack(spacing: 6) {
                    Text(Scrubber.formatted(segment.start))
                    if segment.isEdited {
                        Label("edited", systemImage: "pencil").labelStyle(.titleAndIcon)
                    }
                    if isProvisional {
                        Text("hearing…")
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

            if !isProvisional {
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
        }
        .contextMenu {
            Button("Play from here", systemImage: "play.fill", action: onPlay)
            if !isProvisional {
                Button("Correct this line", systemImage: "pencil", action: onEdit)
            }
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
