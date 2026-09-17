import SwiftUI

/// Lyric-style transcript: the line being spoken is the only bright one, it scrolls
/// itself, tapping a line plays from there, and the pencil beside it corrects the text.
///
/// The controls sit flat above the lines rather than inside a menu. There are only five
/// of them, they're the ones you reach for while listening, and a menu made every one of
/// them a tap-and-hunt — worse, it hid whether anything was running at all.
struct TranscriptPane: View {
    @ObservedObject var transcript = LiveTranscript.shared
    let currentTime: TimeInterval
    /// The whole player page scrolls as one, so the lyric list doesn't own a scroller —
    /// it drives the page's, which is what lets the artwork scroll away as lines advance.
    let scrollProxy: ScrollViewProxy
    /// Turned off by the page the moment the reader scrolls by hand. Auto-scroll pulling
    /// the text back mid-sentence is worse than no auto-scroll at all.
    @Binding var isFollowing: Bool
    let onSeek: (TimeInterval) -> Void

    @ObservedObject private var languages = OnDeviceLanguages.shared
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
        .task { await languages.refreshIfNeeded() }
    }

    /// Every option, in view, in a fixed place. The switch reads as the state it is —
    /// nothing is transcribed until it's on, for this episode only — and the settings it
    /// governs sit under it, dimmed while it's off rather than hidden, so the screen
    /// doesn't reflow as you flip it.
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

            Toggle("Transcribe this episode", isOn: liveSelection)
                .font(.subheadline)
                .disabled(transcript.track == nil)

            Picker("Recogniser", selection: engineSelection) {
                ForEach(TranscriptionEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!transcript.isLiveEnabled)

            HStack(spacing: 12) {
                // Still a menu: it's a list of every language the phone can recognise,
                // which is a picker, not a row of buttons. Value-only and `Equatable`
                // because this pane redraws several times a second while a window is
                // being recognised, and SwiftUI shuts a `Menu` it rebuilds underneath.
                TranscriptLanguageMenu(
                    localeIdentifier: transcript.localeIdentifier,
                    readyLanguages: languages.ready,
                    hasCheckedLanguages: languages.hasChecked
                )
                .equatable()
                Spacer()
                Button("Transcribe again…") { confirmingReload = true }
                    .font(.caption)
                    .disabled(transcript.track == nil)
            }

            // Following playback is the default, so the episode you walked away from
            // stops costing battery. Running ahead is the deliberate choice.
            Toggle("Keep going while paused", isOn: pausedSelection)
                .font(.footnote)
                .disabled(!transcript.isLiveEnabled)
        }
        .padding(.horizontal)
    }

    private var liveSelection: Binding<Bool> {
        Binding(get: { transcript.isLiveEnabled }, set: { transcript.isLiveEnabled = $0 })
    }

    private var engineSelection: Binding<TranscriptionEngineKind> {
        Binding(get: { transcript.engineKind }, set: { transcript.engineKind = $0 })
    }

    private var pausedSelection: Binding<Bool> {
        Binding(get: { transcript.runsWhilePaused }, set: { transcript.runsWhilePaused = $0 })
    }

    private var status: String? {
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
    private var emptyStateDetail: String {
        if let window = transcript.activeWindow {
            return "Working through \(Scrubber.formatted(window.start))–\(Scrubber.formatted(window.end)) — lines appear as they're recognised. Nothing yet means no speech has been made out so far."
        }
        if transcript.isWaitingForPlayback {
            return "Waiting for playback — transcribing follows the episode. Turn on \u{201C}Keep going while paused\u{201D} above to let it run ahead on its own."
        }
        if transcript.isLiveEnabled {
            return "Listening from where you are — lines appear as they're recognised."
        }
        return "Off for this episode — switch \u{201C}Transcribe this episode\u{201D} on above to start. Anything transcribed before, or a transcript file sitting beside the episode, still shows here either way."
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
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcript.lines) { segment in
                    TranscriptLine(
                        segment: segment,
                        isCurrent: segment.start == transcript.currentLine(at: currentTime)?.start,
                        isProvisional: transcript.isProvisional(segment),
                        onPlay: { onSeek(segment.start) },
                        onEdit: { editing = segment }
                    )
                    .id(segment.start)
                }
                // One view with one identity, however often the words inside it change.
                // Giving each in-flight phrase its own row made the list churn on every
                // revision — several times a second — and nothing would hold still.
                if !transcript.volatilePhrases.isEmpty {
                    VolatileTail(phrases: transcript.volatilePhrases)
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

/// The language the recognizer should expect. Value-only and `Equatable` on purpose: the
/// pane redraws several times a second while a window is being recognised, and SwiftUI
/// shuts an open `Menu` whose content it rebuilds — which made this impossible to reach
/// at exactly the moment you'd want it. Writes go straight to the shared `LiveTranscript`
/// rather than through a binding, since a binding would defeat the equality check.
private struct TranscriptLanguageMenu: View, Equatable {
    let localeIdentifier: String?
    /// BCP-47 languages this phone can recognise offline, so the picker can say so before
    /// you pick one rather than after it fails.
    let readyLanguages: Set<String>
    let hasCheckedLanguages: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localeIdentifier == rhs.localeIdentifier
            && lhs.hasCheckedLanguages == rhs.hasCheckedLanguages
            && lhs.readyLanguages == rhs.readyLanguages
    }

    var body: some View {
        Menu {
            // The phone's language says nothing about the episode's, and picking the
            // wrong recognizer doesn't fail — it returns confident nonsense forever.
            Picker("Language", selection: languageSelection) {
                Text("Match this phone").tag(String?.none)
                ForEach(orderedLocales, id: \.identifier) { locale in
                    Text(label(for: locale)).tag(String?.some(locale.identifier(.bcp47)))
                }
            }
        } label: {
            Label("Language: \(languageLabel)", systemImage: "globe")
                .font(.caption)
        }
    }

    private var languageLabel: String {
        guard let localeIdentifier else { return "Automatic" }
        return TranscriptPane.languageName(Locale(identifier: localeIdentifier))
    }

    /// Languages with a model already on this phone come first — that's the practical
    /// difference between a choice that works offline and one that has to download first.
    private var orderedLocales: [Locale] {
        let all = AppleSpeechTranscriber.supportedLocales
        guard hasCheckedLanguages else { return all }
        let ready = all.filter { readyLanguages.contains($0.identifier(.bcp47)) }
        return ready + all.filter { !readyLanguages.contains($0.identifier(.bcp47)) }
    }

    private func label(for locale: Locale) -> String {
        let name = TranscriptPane.languageName(locale)
        guard hasCheckedLanguages else { return name }
        return readyLanguages.contains(locale.identifier(.bcp47)) ? "\(name) · on this iPhone" : name
    }

    private var languageSelection: Binding<String?> {
        Binding(get: { localeIdentifier }, set: { LiveTranscript.shared.localeIdentifier = $0 })
    }
}

/// The words the recognizer hasn't finished with. Rendered as one block rather than a row
/// per phrase so it keeps a single identity in the list — it is rewritten several times a
/// second, and anything keyed off its contents would thrash. No timestamps and no tap
/// target, because none of it is settled enough to seek to.
private struct VolatileTail: View {
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

private struct TranscriptLine: View {
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
