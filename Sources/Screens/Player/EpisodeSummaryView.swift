import SwiftUI

/// What the episode is about, in a few lines — written by the AI pass over the transcript
/// or typed by hand, and editable either way.
///
/// **Three lines until asked.** A summary sits in the middle of a card of fields, above a
/// transcript that's the rest of the page; at full height it pushes everything anyone came
/// here for off the screen. Three lines is enough to know whether to open it.
///
/// **Edit only when open.** A pencil next to three clipped lines edits something you
/// can't see. Expanding is the first half of deciding to change it, so the button appears
/// there.
///
/// **The times are the point.** `[12:14]` in the text is a tap that plays from 12:14 —
/// see `EpisodeSummary`. A summary of a forty-minute episode that can't take you to the
/// minute it's describing is a paragraph about a file.
struct EpisodeSummaryView: View {
    let track: Track

    @State private var summary: String
    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isRunning = false
    @State private var errorMessage: String?
    @FocusState private var isTyping: Bool

    /// Refreshed when the pass finishes, so the Terms card below redraws with it.
    var onAnalyzed: (() -> Void)?

    /// Bumped by the one ✨ on the page, up in the Episode card's heading. The summary
    /// has no button of its own: two sparkles on one page, doing two halves of the same
    /// "read this episode and tell me about it", is a choice nobody wanted to make.
    var analyzeRequest: Int = 0

    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let summarizer = EpisodeSummarizer()

    init(track: Track, analyzeRequest: Int = 0, onAnalyzed: (() -> Void)? = nil) {
        self.track = track
        self.analyzeRequest = analyzeRequest
        self.onAnalyzed = onAnalyzed
        _summary = State(initialValue: track.summary ?? "")
    }

    private var hasTranscript: Bool { summarizer.hasTranscript(trackID: track.id) }

    /// Long enough for three lines to be a clipping rather than the whole thing. A
    /// "More" that reveals nothing is worse than no More at all, so a two-line summary
    /// has neither — and counts as open, which is what puts Edit within reach of it.
    private var isLong: Bool { summary.count > 150 || summary.contains("\n") }
    private var isOpen: Bool { isExpanded || !isLong }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isEditing {
                editor
            } else if summary.isEmpty {
                Text(hasTranscript
                     ? "Nothing yet. ✨ above writes one from the transcript — what it is, the moments worth going back to, and where it lands."
                     : "Nothing yet. Transcribe this episode and ✨ above will write one; or write your own.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .onTapGesture { beginEditing() }
            } else {
                text
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        // Nothing is written over: a summary already here — typed or generated — is what
        // the page shows, and the run that produced it only fills a blank. To have
        // another written, clear this one and ask again, which is the same rule the
        // fields above follow.
        .task(id: analyzeRequest) {
            guard analyzeRequest > 0, summary.isEmpty, hasTranscript, !isRunning else { return }
            await analyze()
        }
        // A track can change under the page while it plays on.
        .onChange(of: track.id) { _, _ in
            summary = track.summary ?? ""
            isEditing = false
            isExpanded = false
        }
        .onChange(of: track.summary ?? "") { _, incoming in
            guard !isEditing, incoming != summary else { return }
            summary = incoming
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("SUMMARY").sectionHeading()
            Spacer()
            if isRunning {
                ProgressView().controlSize(.mini)
            } else if isOpen, !isEditing, !summary.isEmpty {
                Button("Edit") { beginEditing() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EpisodeSummary.attributed(summary))
                .font(.footnote)
                .lineLimit(isOpen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Every `[12:14]` in the text is a link; this is what they do.
                .environment(\.openURL, OpenURLAction { url in
                    guard let seconds = EpisodeSummary.seconds(inURL: url) else { return .systemAction }
                    play(at: seconds)
                    return .handled
                })
            if isLong {
                Button(isExpanded ? "Less" : "More") {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("What this episode is about", text: $draft, axis: .vertical)
                .font(.footnote)
                .lineLimit(4...20)
                .focused($isTyping)
            HStack(spacing: 12) {
                Button("Cancel") {
                    isEditing = false
                    isTyping = false
                }
                .font(.caption)
                Spacer(minLength: 0)
                Button("Save") { save() }
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            // Times keep working in what you typed, so a hand-written summary can point
            // at moments too.
            Text("[12:34] anywhere in the text plays from there.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func beginEditing() {
        draft = summary
        isExpanded = true
        isEditing = true
        isTyping = true
    }

    private func save() {
        summary = draft.trimmed
        try? trackStore.setSummary(id: track.id, summary: summary)
        isEditing = false
        isTyping = false
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func analyze() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            let result = try await summarizer.run(track: track)
            summary = result.summary
            isExpanded = true
            onAnalyzed?()
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Plays from the marked moment — the episode this summary belongs to, whether or not
    /// it's the one currently loaded.
    private func play(at seconds: TimeInterval) {
        let engine = PlaybackEngine.shared
        if engine.currentTrack?.id == track.id {
            engine.seek(to: seconds)
            engine.resume()
        } else {
            engine.open(track: track, queue: [track], startingAt: seconds)
        }
    }
}
