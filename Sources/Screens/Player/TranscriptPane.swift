import SwiftUI
import UIKit

/// Lyric-style transcript: the line being spoken is the only bright one, it scrolls
/// itself, tapping a line plays from there and reads along, and holding a line down
/// offers to mark it, copy it or correct it.
///
/// Two buttons above it, one per recogniser: each transcribes the whole episode in the
/// background, storing each window as it lands — so leaving the app costs the window in
/// flight rather than the hour — and putting the finished transcript up in one piece.
/// Nothing is shown while a
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
    /// Stops playback. Both ways into working on the text call it — see `edit` and
    /// `beginSelecting`.
    let onPause: () -> Void
    let onSeek: (TimeInterval) -> Void

    /// The line being rewritten, and what it says so far. Editing happens in the row
    /// itself: the lines around it are the context you're correcting against, and a sheet
    /// or a page covers exactly those.
    @State private var editingStart: Double?
    @State private var editText = ""
    @State private var showingEdits = false
    /// The recogniser waiting on "yes, spend that" — only ever one that charges.
    @State private var confirmingEngine: TranscriptionEngineKind?
    /// The find-in-episode bar, and what was last typed into it. The words outlive the
    /// bar on purpose: looking for the same phrase again is most of what this is for, and
    /// the bar closes itself the moment a line is picked.
    @State private var isSearching = false
    /// Which lines are picked out, by start time. Non-empty *is* select mode — a separate
    /// flag would allow a mode with nothing selected, which has no actions and nothing to
    /// say, and then needs its own way out.
    @State private var selection: Set<Double> = []
    /// The line being cut in two, while the sheet is up.
    @State private var splitting: TranscriptSegment?
    @State private var searchQuery = ""
    @State private var hits: [TranscriptPhraseSearch.Hit] = []
    @FocusState private var isTypingSearch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Replaces the recogniser row rather than stacking under it: the two have
            // nothing to do with each other, and offering to start a new pass over the
            // lines someone is halfway through rearranging is offering to destroy them.
            if selection.isEmpty { controls } else { selectionBar }
            if let status {
                Text(status).sectionRowSecondary().padding(.horizontal)
            }
            if let lastError = transcript.lastError {
                Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
            }
            lines
        }
        // The lines are already in memory, so this is a scan of an array rather than a
        // query — `task(id:)` is here to keep it off the body pass, not to wait.
        .task(id: searchQuery) {
            hits = TranscriptPhraseSearch.hits(for: searchQuery, in: transcript.lines)
        }
        .sheet(item: $splitting) { segment in
            SplitPhraseSheet(segment: segment) { offset, time in
                transcript.splitLine(segment, atCharacter: offset, atTime: time)
                selection = []
            }
        }
        .sheet(isPresented: $showingEdits) {
            TranscriptEditsView(edits: transcript.edits)
        }
        // Asked before a penny is spent, and before an existing transcript is written
        // over — the second one matters more, because it's the one that can't be undone
        // once the replacement has gone up to the bucket.
        .confirmationDialog(
            transcript.wouldReplaceExisting ? "Replace this transcript?" : "Transcribe with AI?",
            isPresented: Binding(get: { confirmingEngine != nil }, set: { if !$0 { confirmingEngine = nil } }),
            presenting: confirmingEngine
        ) { engine in
            Button(
                transcript.wouldReplaceExisting ? "Replace" : "Transcribe",
                role: transcript.wouldReplaceExisting ? .destructive : nil
            ) {
                confirmingEngine = nil
                transcript.run(engine: engine)
            }
            Button("Cancel", role: .cancel) { confirmingEngine = nil }
        } message: { engine in
            Text(confirmMessage(for: engine))
        }
    }

    /// One button per recogniser, and nothing else. Each one transcribes the whole
    /// episode; the one that's running says so and stops when pressed again. Which
    /// recogniser to use is the only real choice here — free and on this phone, or more
    /// accurate and charged for — so it's two buttons rather than a switch, a picker and
    /// a mode to understand first.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("TRANSCRIPT").sectionHeading()
                searchToggle
                Spacer()
                if !transcript.edits.isEmpty {
                    Button("\(transcript.edits.count) edit\(transcript.edits.count == 1 ? "" : "s")") { showingEdits = true }
                        .font(.caption)
                }
            }
            .id(Self.searchAnchor)

            if isSearching { searchBar }

            // Offered only until the next pass or a change of episode — it restores from a
            // copy held in memory for exactly that long.
            if transcript.canRejectLastPass {
                HStack(spacing: 8) {
                    Text("New transcript").font(.caption).foregroundStyle(.secondary)
                    Button("Reject") { transcript.rejectLastPass() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                // First, because it's the cheapest and most likely to be what you want:
                // a transcript someone already made beats recognising the audio again.
                TranscriptControlButton(
                    title: transcript.isFetchingRemote ? "Fetching…" : "Remote",
                    systemImage: transcript.isFetchingRemote ? "arrow.down.circle.dotted" : "arrow.down.circle",
                    isOn: transcript.isFetchingRemote
                ) { transcript.loadRemoteTranscript() }
                    .disabled(transcript.track == nil || transcript.isRunning || transcript.isFetchingRemote)

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

    /// Where the page scrolls to when the bar opens.
    private static let searchAnchor = "transcript-search"

    private var searchToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isSearching.toggle() }
            isTypingSearch = isSearching
            guard isSearching else { return }
            // The bar opens near the bottom of the page, under the transport and the
            // floating buttons — and the hits appear below it, further under still. So
            // the heading is pulled to the top of the screen, which is also the half the
            // keyboard leaves. Following is turned off for the same reason it is when a
            // line is edited: it would scroll all of this away mid-word.
            isFollowing = false
            withAnimation(.easeOut(duration: 0.25)) {
                scrollProxy.scrollTo(Self.searchAnchor, anchor: .top)
            }
        } label: {
            Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSearching ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
        .disabled(transcript.lines.isEmpty)
    }

    /// The bar and what it found, together: the answers belong under the words that asked
    /// for them, not somewhere down the page behind the keyboard.
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Find in this episode", text: $searchQuery)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isTypingSearch)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            if !searchQuery.isEmpty { hitList }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private var hitList: some View {
        if hits.isEmpty {
            Text("Nothing said in this episode matches").sectionRowSecondary()
        } else {
            Text(hitSummary).font(.caption2).foregroundStyle(.secondary)
            // Its own scroller, kept short: the page behind it is the transcript, and a
            // list of hits as long as the episode would bury it.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hits) { hit in
                        Button { jump(to: hit) } label: { hitRow(hit) }
                            .buttonStyle(.plain)
                        if hit.id != hits.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func hitRow(_ hit: TranscriptPhraseSearch.Hit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hit.text).font(.footnote).foregroundStyle(.primary).lineLimit(2)
            Text(Scrubber.formatted(hit.start)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var hitSummary: LocalizedStringKey {
        if hits.count >= TranscriptPhraseSearch.limit { return "First \(TranscriptPhraseSearch.limit) matches" }
        return hits.count == 1 ? "1 match" : "\(hits.count) matches"
    }

    /// Picking a line is the end of searching: playback moves there, the transcript
    /// scrolls to it and follows on, and the bar folds away — with the words still in it
    /// for the next time the magnifier is tapped.
    private func jump(to hit: TranscriptPhraseSearch.Hit) {
        isTypingSearch = false
        withAnimation(.easeOut(duration: 0.18)) { isSearching = false }
        onSeek(hit.start)
        isFollowing = true
        withAnimation(.easeOut(duration: 0.25)) { scrollProxy.scrollTo(hit.start, anchor: .center) }
    }

    /// Says the thing that can't be taken back first. The price, where there is one,
    /// comes after — money spent is recoverable in a way an overwritten transcript isn't.
    private func confirmMessage(for engine: TranscriptionEngineKind) -> String {
        guard transcript.wouldReplaceExisting else { return estimate(for: engine) }
        var text = """
        This replaces the transcript you already have and uploads the new one over the \
        copy beside the audio in your storage. Lines you corrected by hand are kept.
        """
        if engine.pricePerMinuteUSD != nil { text += "\n\n" + estimate(for: engine) }
        return text
    }

    private func engineButton(_ engine: TranscriptionEngineKind) -> some View {
        let isRunningThis = transcript.runningEngine == engine
        return TranscriptControlButton(
            title: title(for: engine),
            systemImage: isRunningThis ? "stop.fill" : engine.symbolName,
            isOn: isRunningThis
        ) {
            // Stopping never asks. Starting asks when it costs money, and asks when it
            // would write over a transcript that's already here — on-device is free but
            // replacing is still replacing.
            guard !isRunningThis else { return transcript.run(engine: engine) }
            guard engine.pricePerMinuteUSD != nil || transcript.wouldReplaceExisting else {
                return transcript.run(engine: engine)
            }
            confirmingEngine = engine
        }
        // The other recogniser waits its turn: two passes over the same audio at once is
        // twice the battery for one transcript.
        .disabled(transcript.track == nil || (transcript.isRunning && !isRunningThis))
    }

    /// The running one says what it's doing rather than what pressing it does — the stop
    /// square already says that, and "Stop" on its own left the page with no word for the
    /// thing taking all this time.
    private func title(for engine: TranscriptionEngineKind) -> LocalizedStringKey {
        guard transcript.runningEngine != engine else { return "Transcribing…" }
        switch engine {
        case .onDevice: return "On-device"
        case .openAIWhisper: return "AI"
        }
    }

    /// What the pass would cost and why it's that much: the length it would actually send,
    /// which on a part-finished episode is a fraction of the episode.
    private func estimate(for engine: TranscriptionEngineKind) -> String {
        let seconds = transcript.untranscribedSeconds
        guard seconds > 0, let cost = transcript.estimatedCost(of: engine) else {
            return "This episode is already transcribed."
        }
        let length = TrackRow.formattedDuration(Int(seconds * 1000))
        let price = cost < 0.01 ? "under $0.01" : "about " + cost.formatted(.currency(code: "USD"))
        let sent = transcript.lines.isEmpty ? "" : " Only the part with no transcript yet is sent."
        return "\(length) of audio, \(price) charged to your own OpenAI key.\(sent)"
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
            return "Working through the episode — \(percent) done. The whole transcript appears here at once when it's finished — and leaving the app doesn't lose what's already done."
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

    /// Marks the moment this line starts, with the line itself as the mark's text — the
    /// most accurate a mark ever gets, since it's the sentence you were looking at rather
    /// than whatever was playing when your thumb landed.
    ///
    /// **It doesn't go anywhere.** The mark is made while you're reading; being thrown up
    /// the page to the Notes section would lose the line you marked it for. It's in the
    /// list when you next look, and the haptic is the receipt.
    private func bookmark(_ segment: TranscriptSegment) {
        guard let track = transcript.track else { return }
        let store = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)
        guard (try? store.add(
            trackID: track.id, positionMs: Int(segment.start * 1000), transcriptText: segment.text
        )) != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }

    /// A tap plays from the line *and* shows what else can be done with it. Tapping the
    /// same line again puts the buttons away.
    /// A tap back, because a pasteboard write is otherwise completely silent — there is
    /// no way to tell "copied" from "the menu didn't fire".
    private func copy(_ segment: TranscriptSegment) {
        UIPasteboard.general.string = segment.text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// What can be done with the picked lines, and the way out. Counting is the first
    /// thing said: in a list of near-identical short lines, how many are held is the thing
    /// most easily lost track of.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selection.count) selected")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
            Spacer(minLength: 0)
            Button("Merge") { merge() }.disabled(!canMerge)
            Button("Split") { splitting = selectedLine }.disabled(selectedLine == nil)
            Button("Done") { selection = [] }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.horizontal)
    }

    private var selectedLine: TranscriptSegment? {
        guard selection.count == 1, let start = selection.first else { return nil }
        return transcript.lines.first { $0.start == start }
    }

    /// Two or more, and adjacent. Merging across a gap would either throw the lines
    /// between away or swallow lines nobody picked — see `TranscriptStore.merge` — so the
    /// button goes dim instead of choosing one of those for you.
    private var canMerge: Bool {
        guard selection.count > 1 else { return false }
        let picked = transcript.lines.indices.filter { selection.contains(transcript.lines[$0].start) }
        guard let first = picked.first, let last = picked.last else { return false }
        return last - first == picked.count - 1
    }

    private func toggleSelected(_ segment: TranscriptSegment) {
        if selection.contains(segment.start) {
            selection.remove(segment.start)
        } else {
            selection.insert(segment.start)
        }
    }

    private func merge() {
        transcript.mergeLines(starts: selection)
        selection = []
    }

    /// Turns the row into a field, where it stands.
    ///
    /// **Playback stops.** Correcting a line means reading the lines around it, and audio
    /// carrying on is either moving the highlight away from the one being typed in or
    /// rolling into the next episode while the keyboard is up.
    ///
    /// **Following goes off**: it would scroll the line being typed in out from under the
    /// keyboard within seconds.
    ///
    /// It does *not* scroll the page. Pulling the row to the top made Edit look like it
    /// had done nothing — the row you were looking at leapt away, and the field ended up
    /// somewhere you weren't. The keyboard moves the page itself if the field needs it.
    private func edit(_ segment: TranscriptSegment) {
        onPause()
        isFollowing = false
        editText = segment.text
        editingStart = segment.start
    }

    /// **Playback stops here too.** Picking lines out to join or cut is reading work, and
    /// the audio running on underneath it does nothing but move the highlight onto a line
    /// nobody is looking at — and, at the end of the episode, start the next one over the
    /// top of what you were in the middle of.
    private func beginSelecting(_ segment: TranscriptSegment) {
        onPause()
        selection = [segment.start]
    }

    private func save(_ segment: TranscriptSegment) {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingStart = nil
        guard !trimmed.isEmpty, trimmed != segment.text else { return }
        transcript.applyEdit(to: segment, newText: trimmed)
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
                    // One `.id` for the row, outside the branch. With the same id on both
                    // arms of the if/else, SwiftUI reads them as one identity and keeps
                    // showing the arm it already had: tapping Edit built the field on
                    // every redraw — the log said so — and never put it on screen.
                    Group {
                        if editingStart == segment.start {
                            InlinePhraseEditor(
                                text: $editText,
                                onSave: { save(segment) },
                                onCancel: { editingStart = nil }
                            )
                        } else {
                            TranscriptLine(
                                segment: segment,
                                isCurrent: segment.start == spokenStart,
                                isSelecting: !selection.isEmpty,
                                isSelected: selection.contains(segment.start),
                                // A tap means "read along from here" normally and "this
                                // one" while lines are being picked — the same press, two
                                // modes, which is why the mode is visible on every row.
                                onPlay: {
                                    if selection.isEmpty { play(from: segment) } else { toggleSelected(segment) }
                                },
                                onBookmark: { bookmark(segment) },
                                onCopy: { copy(segment) },
                                onEdit: { edit(segment) },
                                onSelect: { beginSelecting(segment) }
                            )
                            // Nothing but the text, the highlight and the "still being
                            // revised" flag can change a row, so a redraw of the list
                            // leaves settled rows alone instead of rebuilding hundreds.
                            .equatable()
                        }
                    }
                    .id(segment.start)
                }
            }
            .padding(.horizontal)
            // Never while a line is open for correction. `edit` turns following off, but
            // it can come back on under the keyboard — tapping another line to hear it
            // again mid-correction does exactly that — and the next line spoken then
            // scrolls the field being typed in off the screen.
            .onChange(of: transcript.currentLine(at: currentTime)?.start) { _, start in
                guard isFollowing, editingStart == nil, let start else { return }
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
            // Both belong here or the row keeps the skipped redraw and the tick never
            // appears — the whole list is `.equatable()`, so a selection that isn't part
            // of equality is a selection that doesn't draw.
            && lhs.isSelecting == rhs.isSelecting && lhs.isSelected == rhs.isSelected
    }

    let segment: TranscriptSegment
    let isCurrent: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onPlay: () -> Void
    let onBookmark: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSelect: () -> Void

    /// Text and timestamp, and nothing drawn on top of them. Copy and Edit were capsules
    /// that appeared on the tapped row: they sat under the page's scroll handle, took
    /// enough width to fold the line onto a second row, and Edit was unreliable to hit at
    /// all. Both live on the long press now, which is where a second action on a line of
    /// text belongs and where Play already was.
    var body: some View {
        // A real `Button`, not a tap gesture. `onTapGesture` and `contextMenu` on the same
        // view fight over the press: the tap wins early and the long press never
        // completes, which is why the menu — and so Copy and Edit — did nothing. A button
        // with a menu attached is the pattern a List row uses, and the two coexist.
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 10) {
                // Only while picking. A permanent tick column would indent every line of
                // every transcript for a mode almost nobody is in.
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Nothing on hold while picking: every item here acts on one line, and the
            // press that would open them is also how you'd reach for another tick.
            if !isSelecting {
                Button("Play from here", systemImage: "play.fill", action: onPlay)
                // Second, under Play: holding a line is how you say "this one", and the two
                // things anyone means by it are hear it again and keep it.
                Button("Add bookmark", systemImage: "bookmark.fill", action: onBookmark)
                Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Select", systemImage: "checkmark.circle", action: onSelect)
            }
        }
    }
}

/// A line turned into a field, in place, with the two answers beside it. No Save bar and
/// no sheet: the correction is one line long, and the lines above and below it are the
/// context it's being corrected against.
private struct InlinePhraseEditor: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTyping: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Phrase", text: $text, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .focused($isTyping)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.5))
                }

            Button(action: onSave) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.title3)
        .buttonStyle(.plain)
        // The keyboard is the point of tapping Edit — it shouldn't need a second tap.
        .onAppear { isTyping = true }
    }
}

/// Where to cut one line in two — in the text and in time, because neither answers for
/// the other. The text says where the sentence divides; the time says when the second half
/// starts being spoken, which is what a tap on it will seek to. Guessing the time from the
/// character offset puts that seek in the wrong place on any line whose halves aren't read
/// at the same pace, which is most of them.
///
/// **Both halves stay on screen.** They are the only way to tell a good cut from one that
/// leaves a dangling word, and a sheet showing the controls but not the result would make
/// this a guess with a confirm button.
///
/// The text point snaps to word boundaries where the language has them and moves a
/// character at a time where it doesn't. A Chinese or Japanese transcript has exactly one
/// "word" by any space-based reckoning — and is the transcript that needs splitting most,
/// because a recogniser with no spaces to go on runs whole sentences together.
private struct SplitPhraseSheet: View {
    let segment: TranscriptSegment
    let onSplit: (Int, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var offset: Double
    @State private var time: Double
    /// Until the time is moved by hand it tracks the text point, which is right far more
    /// often than the middle of the line. Once it's been set deliberately it stays put —
    /// having it snap back while the text point is nudged would undo the more careful of
    /// the two decisions.
    @State private var hasSetTime = false

    private let characters: [Character]
    private let boundaries: [Int]

    init(segment: TranscriptSegment, onSplit: @escaping (Int, Double) -> Void) {
        self.segment = segment
        self.onSplit = onSplit
        let characters = Array(segment.text)
        self.characters = characters
        self.boundaries = characters.indices.dropFirst().filter {
            characters[$0 - 1] == " " && characters[$0] != " "
        }
        let middle = characters.count / 2
        let nearest = boundaries.min { abs($0 - middle) < abs($1 - middle) } ?? middle
        _offset = State(initialValue: Double(max(nearest, 1)))
        _time = State(initialValue: (segment.start + segment.end) / 2)
    }

    /// The span, guaranteed non-empty. A `Slider` with an empty range traps, and a stored
    /// transcript from before `end` existed can still decode with the two equal.
    private var span: ClosedRange<Double> { segment.start...max(segment.end, segment.start + 0.02) }

    private var cut: Int { snapped(Int(offset.rounded())) }
    private var before: String { String(characters[..<cut]).trimmingCharacters(in: .whitespaces) }
    private var after: String { String(characters[cut...]).trimmingCharacters(in: .whitespaces) }

    private func snapped(_ index: Int) -> Int {
        let bounded = min(max(index, 1), max(characters.count - 1, 1))
        guard !boundaries.isEmpty else { return bounded }
        return boundaries.min { abs($0 - bounded) < abs($1 - bounded) } ?? bounded
    }

    private var proportionalTime: Double {
        let length = segment.end - segment.start
        guard length > 0, characters.count > 1 else { return span.lowerBound }
        return min(max(segment.start + length * Double(cut) / Double(characters.count), span.lowerBound), span.upperBound)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("First line") { Text(before) }
                Section("Second line") { Text(after) }

                Section {
                    Slider(value: $offset, in: 1...Double(max(characters.count - 1, 1)), step: 1)
                } header: {
                    Text("Where the text divides")
                } footer: {
                    Text(boundaries.isEmpty
                         ? "This line has no spaces to divide on, so it moves one character at a time."
                         : "Snaps to the start of a word.")
                }

                Section {
                    Slider(value: $time, in: span) { editing in
                        if editing { hasSetTime = true }
                    }
                    LabeledContent("Starts at", value: Scrubber.formatted(time))
                        .monospacedDigit()
                } header: {
                    Text("Where the second line starts")
                } footer: {
                    Text("What tapping the second line will play from. It follows the text point until you set it yourself.")
                }
            }
            .navigationTitle("Split line")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: cut) { _, _ in
                guard !hasSetTime else { return }
                time = proportionalTime
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") {
                        onSplit(cut, time)
                        dismiss()
                    }
                    .disabled(before.isEmpty || after.isEmpty)
                }
            }
        }
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
