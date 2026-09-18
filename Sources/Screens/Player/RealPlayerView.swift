import SwiftUI

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingUpNext = false
    @State private var showingAddToPlaylist = false
    @State private var bookmarkCount = 0
    /// How far the page has been pulled past its own top, so it can shrink under the
    /// finger on the way out instead of just vanishing at the threshold.
    @State private var pullDown: CGFloat = 0
    /// How far the header has been dragged down, so the page follows the finger.
    @State private var dragDown: CGFloat = 0
    @State private var isDismissing = false
    @State private var artist: Artist?
    /// Whether the transcript is following playback. Off until asked for: the page opens
    /// at the transport, and text that scrolls itself the moment you arrive takes the
    /// controls out from under your thumb. Any scroll of your own turns it off again.
    @State private var isFollowingTranscript = false
    /// Whether the big transport has scrolled out of sight. The docked bar is a stand-in
    /// for it, so showing both at once is just clutter.
    @State private var isTransportOffscreen = false

    private static let scrollSpace = "player.scroll"
    private static let topAnchor = "player.top"
    private static let transcriptAnchor = "player.transcript"
    /// How far sideways counts as "the next one" rather than a scroll that wandered.
    private static let swipeToChapter: CGFloat = 80
    /// How far past the top the page has to come before it goes away. Read off the scroll
    /// view's overscroll, which rubber-bands: the finger travels two to three times this,
    /// so it's well clear of the idle bounce at the top of a long page without asking for
    /// a stroke longer than the screen.
    private static let pullToDismiss: CGFloat = 70
    /// The same gesture, on the artwork and titles, where a scroll view isn't in the way.
    /// This is the one that actually gets used — a card is put down by dragging the top of
    /// it, not by fighting a transcript for the overscroll underneath.
    private static let dragToDismiss: CGFloat = 110
    /// Read, never observed. A running transcription republishes several times a second,
    /// and observing it here redrew the artwork, the transport and the whole details card
    /// along with the text — which is what made the page flash while transcribing. The
    /// transcript pane does its own observing, so only the text redraws.
    private var transcript: TranscriptRunner { TranscriptRunner.shared }
    @State private var album: Album?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        NavigationStack {
            // One reader around the whole page, so the title in the bar can scroll it too.
            ScrollViewReader { proxy in
                Group {
                    if let track = engine.currentTrack {
                        // One scroll for the whole screen, and one page: details, then the
                        // transcript under them. A segmented control between the two was a
                        // tab bar for two things that are read together — you check who the
                        // speaker is *because* of a line you just read — and it cost a tap
                        // and a lost scroll position every time.
                        page(for: track, proxy: proxy)
                            // Any deliberate drag hands control to the reader.
                            // `simultaneous` so it observes the scroll rather than
                            // competing with it.
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 12).onChanged { _ in
                                    isFollowingTranscript = false
                                }
                            )
                            .overlay(alignment: .bottom) { floatingControls(proxy) }
                            // Pinned: the page is now arbitrarily long, and the transport
                            // shouldn't be a scroll away at the bottom of a 40-minute
                            // transcript.
                            .safeAreaInset(edge: .bottom) {
                                if isTransportOffscreen { bottomBar.transition(.move(edge: .bottom)) }
                            }
                            .animation(.easeInOut(duration: 0.2), value: isTransportOffscreen)
                            .task(id: track.id) {
                                artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
                                album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
                                refreshBookmarkCount(track)
                            }
                            .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
                                refreshBookmarkCount(track)
                            }
                    } else {
                        ContentUnavailableView("Nothing playing", systemImage: "mic.slash")
                    }
                }
                .background(Color.appBackground.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // A card you put down, not a page you back out of: the arrow points
                    // the way the gesture goes, and both leave the same way.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label("Close", systemImage: "chevron.down").font(.body.weight(.semibold))
                        }
                    }
                    // Tapping the title goes back to the top, as it does in every iOS app
                    // whose content runs past the fold.
                    ToolbarItem(placement: .principal) {
                        Button {
                            isFollowingTranscript = false
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                        } label: {
                            Text("Now Playing").font(.headline)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showingUpNext) {
                    UpNextView()
                }
                .sheet(isPresented: $showingAddToPlaylist) {
                    if let track = engine.currentTrack {
                        AddToPlaylistSheet(track: track)
                    }
                }
            }
        }
        // Put the card down by pulling it down — either by dragging its top, or by pulling
        // the whole page past its own top, which the scroll view reports as overscroll. It
        // follows the finger and shrinks as it goes, so the pull is answered before the
        // threshold rather than at it.
        .offset(y: dragDown)
        .scaleEffect(1 - min(max(pullDown, dragDown), Self.pullToDismiss) / 1600, anchor: .center)
        .animation(.interactiveSpring(response: 0.3), value: pullDown)
    }

    /// The two gestures the top of the card carries, told apart by which way the finger
    /// actually went: **down** puts the card away, **sideways** moves a chapter. Dragging
    /// up on the artwork is how you get to the transcript, and that belongs to the scroll
    /// view.
    private var putDownDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragDown = max(0, value.translation.height)
            }
            .onEnded { value in
                let sideways = value.translation.width
                guard abs(value.translation.height) > abs(sideways) else {
                    withAnimation(.easeOut(duration: 0.2)) { dragDown = 0 }
                    guard abs(sideways) > Self.swipeToChapter else { return }
                    // Where a book's pages go: left for the next one, right for the last.
                    sideways < 0 ? engine.skipToNext() : engine.skipToPrevious()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    return
                }
                // The flick counts as well as the distance, so putting it down briskly
                // doesn't need the full stroke.
                let thrown = value.predictedEndTranslation.height > Self.dragToDismiss * 2
                guard value.translation.height > Self.dragToDismiss || thrown else {
                    withAnimation(.easeOut(duration: 0.2)) { dragDown = 0 }
                    return
                }
                guard !isDismissing else { return }
                isDismissing = true
                dismiss()
            }
    }

    /// Split out of `body` purely so the type-checker can cope — it timed out once the
    /// transcript pane grew a binding and the page grew an overlay.
    private func page(for track: Track, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Artwork and titles move together, and carry the put-down gesture: the
                // top of the card is the part of it a hand reaches for, and it's the one
                // part with no scrolling text underneath to fight over the drag.
                VStack(spacing: 20) {
                    artwork(for: track)
                    titles(for: track)
                }
                .gesture(putDownDrag)
                Scrubber(currentTime: engine.currentTime, duration: engine.duration) { engine.seek(to: $0) }
                    .padding(.horizontal)
                transport(for: track)
                    .background { transportVisibilityProbe }
                queueControls(proxy)
                if let lastError = engine.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                EpisodeDetailsPane(playingTrack: track)

                Divider()
                    .padding(.horizontal)
                    .id(Self.transcriptAnchor)

                TranscriptPane(
                    currentTime: engine.currentTime,
                    scrollProxy: proxy,
                    isFollowing: $isFollowingTranscript,
                    onFollow: { follow(proxy) }
                ) { engine.seek(to: $0) }

            }
            .padding(.vertical)
            .background { scrollProbe }
        }
        .coordinateSpace(name: Self.scrollSpace)
        // The page draws its own bar below; the system's would sit a few points
        // beside it, two indicators of different lengths down the same edge.
        .scrollIndicators(.hidden)
        // The details are edited in place, so a keyboard can be up over a page that
        // scrolls — dragging it away is how everyone expects to be rid of it.
        .scrollDismissesKeyboard(.interactively)
    }

    private func artwork(for track: Track) -> some View {
        ArtworkTile(track: track, cornerRadius: 16, symbolSize: 64)
            .frame(height: 220)
            .padding(.horizontal)
            .id(Self.topAnchor)
            // The big empty area at the top of the page doubles as "I'm done typing".
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Jumps to the line being spoken and keeps up from there. Asked for, never assumed —
    /// see `isFollowingTranscript`.
    private func follow(_ proxy: ScrollViewProxy) {
        guard let start = transcript.currentLine(at: engine.currentTime)?.start else { return }
        isFollowingTranscript = true
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(start, anchor: .center) }
    }

    private func titles(for track: Track) -> some View {
        VStack(spacing: 4) {
            Text(track.title).font(.title3.bold()).multilineTextAlignment(.center)
            // Under the title everywhere it appears: a shared embedded title tag makes
            // two episodes read identically, and the path is what separates them.
            Text(TrackRow.pathHint(for: track))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            // Tapping either jumps to that speaker's/album's own page — same
            // destinations as tapping through from Home, just reachable from
            // whatever's currently playing too. One line rather than stacked,
            // since together they're still just a single subtitle.
            HStack(spacing: 12) {
                if let artist {
                    NavigationLink {
                        SpeakerDetailView(speaker: artist)
                    } label: {
                        Text("Speaker: \(artist.name)")
                    }
                }
                if let album {
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        Text("Album: \(album.name)")
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal)
    }

    /// Favourite and bookmark flank the transport rather than sitting in a menu: both are
    /// things you do *because of what you're hearing right now*, and a mark you have to go
    /// looking for is a mark made too late.
    private func transport(for track: Track) -> some View {
        HStack(spacing: 28) {
            Button {
                toggleFavorite(track)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(track.isFavorite ? AnyShapeStyle(Color.pink) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            }
            .accessibilityLabel(track.isFavorite ? "Remove from favourites" : "Add to favourites")

            Button { engine.skipToPrevious() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { engine.skipToNext() } label: { Image(systemName: "forward.fill").font(.title) }

            Button {
                addBookmark(to: track)
            } label: {
                Image(systemName: bookmarkCount > 0 ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .overlay(alignment: .topTrailing) {
                        if bookmarkCount > 0 {
                            Text("\(bookmarkCount, format: .number.grouping(.never))")
                                .font(.system(size: 9, weight: .bold))
                                .padding(3)
                                .background(Color.accentColor, in: Circle())
                                .foregroundStyle(.white)
                                .offset(x: 10, y: -8)
                        }
                    }
            }
            .accessibilityLabel("Bookmark this moment")
        }
    }

    /// The list actions and the way down to the text, under the transport where the rest
    /// of the controls are — they used to be a menu in the top-left corner, which is
    /// nowhere near the thumb and hid the queue's length.
    ///
    /// "Transcript" rather than lyrics, subtitles or captions: lyrics are for songs, and
    /// subtitles are text laid over a picture. It's the word the rest of the app uses, for
    /// the heading, the files beside the audio and what travels in a backup.
    private func queueControls(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button { showingUpNext = true } label: {
                Label("Chapters (\(engine.queue.count, format: .number.grouping(.never)))", systemImage: "list.bullet")
            }
            Button { showingAddToPlaylist = true } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            // The details card sits between the transport and the text, so on an episode
            // with a transcript this saves a long scroll past everything you already know.
            Button {
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.transcriptAnchor, anchor: .top) }
            } label: {
                Label("Transcript", systemImage: "captions.bubble")
            }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    private func toggleFavorite(_ track: Track) {
        try? trackStore.setFavorite(id: track.id, isFavorite: !track.isFavorite)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func addBookmark(to track: Track) {
        // The line being spoken travels with the mark: what was said there is the reason
        // it was marked, and a re-transcribe shouldn't be able to rewrite that.
        let spoken = transcript.currentLine(at: engine.currentTime)?.text
        try? bookmarkStore.add(
            trackID: track.id, positionMs: Int(engine.currentTime * 1000), transcriptText: spoken
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)
    }

    private func refreshBookmarkCount(_ track: Track) {
        bookmarkCount = ((try? bookmarkStore.all(forTrack: track.id)) ?? []).count
    }

    /// Watches where the big transport has got to, so the docked bar can stand in for it
    /// only once it's actually gone.
    ///
    /// The two thresholds are not the same number on purpose. Showing the bar shortens the
    /// scroll view, which nudges the transport back down — with a single threshold that
    /// feeds straight back into the test and the bar flickers on and off. The dead zone
    /// between them is wider than the bar is tall, so it can't chase itself.
    private var transportVisibilityProbe: some View {
        GeometryReader { proxy in
            let bottomEdge = proxy.frame(in: .named(Self.scrollSpace)).maxY
            Color.clear.onChange(of: bottomEdge, initial: true) { previous, edge in
                _ = previous
                if isTransportOffscreen {
                    if edge > 96 { isTransportOffscreen = false }
                } else if edge < 0 {
                    isTransportOffscreen = true
                }
            }
        }
    }

    /// The two things you want from deep inside a 40-minute transcript: back to the
    /// artwork and the transport, and back to the line being spoken. Both are a reach
    /// away from the bottom of the page, where the thumb already is — the copies at the
    /// top of the transcript are a scroll away by the time you need them.
    ///
    /// "Back to top" also stops the page moving itself: following and reading the top of
    /// the page are contradictory things to want.
    @ViewBuilder
    private func floatingControls(_ proxy: ScrollViewProxy) -> some View {
        if isTransportOffscreen {
            HStack(spacing: 10) {
                floatingButton("Back to top", systemImage: "arrow.up", isOn: false) {
                    isFollowingTranscript = false
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
                if !transcript.lines.isEmpty {
                    // A toggle here, where the one above the transcript only turns it on:
                    // this one is in reach of the thumb that just scrolled away from the
                    // spoken line, and stopping is as likely to be the ask as starting.
                    // One label, one icon — colour alone says whether it's on, so the
                    // button doesn't change shape under the thumb that just pressed it.
                    floatingButton("Follow", systemImage: "location.fill", isOn: isFollowingTranscript) {
                        if isFollowingTranscript { isFollowingTranscript = false } else { follow(proxy) }
                    }
                }
            }
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    private func floatingButton(
        _ title: String,
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(Material.ultraThin),
                            in: Capsule())
                .overlay(
                    Capsule().stroke(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                )
        }
        .buttonStyle(.plain)
    }

    /// Watches the page go by, for one purpose: whether it's being pulled off the top.
    /// One probe behind the whole content, rather than the transport's — that one stopped
    /// being a useful signal the moment it scrolled off the top.
    private var scrollProbe: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(Self.scrollSpace))
            Color.clear
                .onChange(of: frame.minY, initial: true) { _, minY in
                    // Above its own top: the page is being pulled off, not scrolled.
                    pullDown = max(0, minY)
                    if pullDown > Self.pullToDismiss, !isDismissing {
                        isDismissing = true
                        dismiss()
                    }
                }
        }
    }

    /// Docked, so play/pause and position are reachable from anywhere on a page that is
    /// now arbitrarily long. Reading forty minutes of transcript must never mean scrolling
    /// back to the top to stop playback.
    private var bottomBar: some View {
        VStack(spacing: 0) {
            ProgressView(value: engine.duration > 0 ? min(engine.currentTime / engine.duration, 1) : 0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)

            HStack(spacing: 14) {
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Text("\(Scrubber.formatted(engine.currentTime)) / \(Scrubber.formatted(engine.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button { engine.skipToNext() } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(.horizontal)
        }
        .background(.ultraThinMaterial)
    }
}

/// Drives itself from a locally-held drag position while the user's finger is down, so
/// `PlaybackEngine`'s periodic `currentTime` publishing (every 0.5s) can't yank the thumb
/// back mid-drag. A zero-distance drag gesture also means tapping anywhere on the track
/// jumps straight there, not just dragging the thumb.
struct Scrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var displayedTime: TimeInterval { isDragging ? dragTime : currentTime }
    private var progress: Double { duration > 0 ? min(max(displayedTime / duration, 0), 1) : 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 4)
                    Capsule().fill(Color.accentColor).frame(width: geo.size.width * progress, height: 4)
                    Circle().fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .offset(x: geo.size.width * progress - 7)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragTime = time(atX: value.location.x, width: geo.size.width)
                        }
                        .onEnded { value in
                            let time = time(atX: value.location.x, width: geo.size.width)
                            onSeek(time)
                            isDragging = false
                        }
                )
            }
            .frame(height: 20)
            HStack {
                Text(Self.formatted(displayedTime))
                Spacer()
                Text(Self.formatted(duration))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }

    static func formatted(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct UpNextView: View {
    @ObservedObject var engine = PlaybackEngine.shared

    var body: some View {
        NavigationStack {
            List(engine.queue) { track in
                Button {
                    engine.play(track: track, queue: engine.queue)
                } label: {
                    HStack {
                        if track.id == engine.currentTrack?.id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(TrackRow.fileName(for: track))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
