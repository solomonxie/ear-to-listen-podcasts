import SwiftUI

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingUpNext = false
    @State private var showingAddToPlaylist = false
    @State private var bookmarkCount = 0
    /// Bumped by every scroll, so the rail can show itself while the page is moving and
    /// get out of the way again when it stops.
    @State private var scrollTick = 0
    @State private var isRailShowing = false
    /// How far down the whole page the reader is, 0…1, and how much of it there is to
    /// scroll. Measured rather than inferred from the transcript, so the rail means the
    /// same thing on an episode with no transcript at all.
    @State private var scrollFraction: Double = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// How far a back-swipe from the left edge has got, so the page follows the finger
    /// rather than jumping when it's let go.
    @State private var backSwipe: CGFloat = 0
    @State private var artist: Artist?
    /// Whether the transcript is following playback. Off until asked for: the page opens
    /// at the transport, and text that scrolls itself the moment you arrive takes the
    /// controls out from under your thumb. Any scroll of your own turns it off again.
    @State private var isFollowingTranscript = false
    /// Where the drag on the rail has got to, 0…1. Nil when nobody's holding it, so the
    /// rail shows where the page actually is instead.
    @State private var railFraction: Double?
    /// Whether the big transport has scrolled out of sight. The docked bar is a stand-in
    /// for it, so showing both at once is just clutter.
    @State private var isTransportOffscreen = false

    private static let scrollSpace = "player.scroll"
    private static let topAnchor = "player.top"
    private static let bottomAnchor = "player.bottom"
    private static let transcriptAnchor = "player.transcript"
    private static let railHandleSize: CGFloat = 46
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
                            .overlay(alignment: .trailing) { scrollRail(proxy) }
                            .overlay(alignment: .bottom) { backToTopButton(proxy) }
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
                    // A page, not a card: it has a back button where every other page has
                    // one, and the same edge swipe.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Label("Back", systemImage: "chevron.left").font(.body.weight(.semibold))
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
        .offset(x: backSwipe)
        // A strip at the leading edge rather than a gesture over the page: the page is a
        // scroll view, and a swipe anywhere in it belongs to the scroll view.
        .overlay(alignment: .leading) { backSwipeCatcher }
    }

    private var backSwipeCatcher: some View {
        Color.clear
            .frame(width: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { backSwipe = max(0, $0.translation.width) }
                    .onEnded { value in
                        if value.translation.width > 90 || value.predictedEndTranslation.width > 220 {
                            dismiss()
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { backSwipe = 0 }
                        }
                    }
            )
    }

    /// Split out of `body` purely so the type-checker can cope — it timed out once the
    /// transcript pane grew a binding and the page grew an overlay.
    private func page(for track: Track, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                artwork(for: track)
                titles(for: track)
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

                Color.clear.frame(height: 1).id(Self.bottomAnchor)
            }
            .padding(.vertical)
            .background { scrollProbe }
        }
        .coordinateSpace(name: Self.scrollSpace)
        // The page draws its own bar below; the system's would sit a few points
        // beside it, two indicators of different lengths down the same edge.
        .scrollIndicators(.hidden)
        // How much of the page fits at once — half of what the rail needs to know. An
        // overlay rather than a wrapper so nothing about the layout changes to measure it.
        .overlay {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                    viewportHeight = height
                }
            }
            .allowsHitTesting(false)
        }
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
                Label("Up Next (\(engine.queue.count, format: .number.grouping(.never)))", systemImage: "list.bullet")
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
                if previous != edge { showRail() }
                if isTransportOffscreen {
                    if edge > 96 { isTransportOffscreen = false }
                } else if edge < 0 {
                    isTransportOffscreen = true
                }
            }
        }
    }

    /// The way back to the artwork and the transport from anywhere in a 40-minute
    /// transcript — and the way to stop the page moving itself, since following and
    /// reading the top of the page are contradictory things to want. Centred: it's a
    /// thumb-reach control, and off to one side it sat under the scroll rail.
    @ViewBuilder
    private func backToTopButton(_ proxy: ScrollViewProxy) -> some View {
        if isTransportOffscreen {
            Button {
                isFollowingTranscript = false
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            } label: {
                Label("Back to top", systemImage: "arrow.up")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
    }

    /// The page's own scroller: where the reader is, and a way to get somewhere else
    /// quickly on a page that runs to hundreds of lines. Measured from the scroll view
    /// rather than guessed from the transcript, so it means the same thing on an episode
    /// with no text at all.
    ///
    /// A handle you can see and hit, not a hairline: a 3pt bar down the edge of a page of
    /// text was there in principle and unfindable in practice. It never leaves while the
    /// page is long enough to need it — it only dims once the page has been still a few
    /// seconds, so it stops pulling at the eye without going away on the reader.
    @ViewBuilder
    private func scrollRail(_ proxy: ScrollViewProxy) -> some View {
        // Nothing to drag on a page that fits.
        if contentHeight > viewportHeight + 120 {
            GeometryReader { geometry in
                let height = geometry.size.height
                let travel = max(height - Self.railHandleSize, 1)
                let isDragging = railFraction != nil
                Color.clear
                    .overlay(alignment: .top) {
                        railHandle(isDragging: isDragging)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(y: travel * (railFraction ?? scrollFraction))
                            .animation(.easeOut(duration: 0.15), value: isDragging)
                    }
                    // The hit area is the whole strip beside the handle too: a control you
                    // have to hit exactly is one nobody uses.
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // Held by its middle wherever it's caught, so the page
                                // doesn't jump on the first touch.
                                let fraction = (value.location.y - Self.railHandleSize / 2) / travel
                                railFraction = min(max(fraction, 0), 1)
                                isFollowingTranscript = false
                                showRail()
                                scroll(to: railFraction ?? 0, proxy: proxy)
                            }
                            .onEnded { _ in
                                railFraction = nil
                                showRail()
                            }
                    )
            }
            .frame(width: 56)
            .padding(.trailing, 4)
            .padding(.vertical, 60)
            // Dimmed, never gone: a control that vanishes is one you have to make reappear
            // before you can use it, and scrolling to find the thing that scrolls is silly.
            .opacity(isRailShowing ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.4), value: isRailShowing)
            // Restarted by every scroll — `task(id:)` cancels the pending dim, so the
            // handle stays up for as long as the page keeps moving.
            .task(id: scrollTick) {
                guard isRailShowing else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if railFraction == nil { isRailShowing = false }
            }
        }
    }

    /// Big enough to find and to hold: a thumb-sized disc carrying the one gesture it
    /// takes — drag me up or down. It takes the accent colour under a finger, where the
    /// disc itself is hidden by the hand holding it and only its colour still reads.
    private func railHandle(isDragging: Bool) -> some View {
        Image(systemName: "arrow.up.and.down")
            .font(.footnote.weight(.bold))
            .foregroundStyle(isDragging ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: Self.railHandleSize, height: Self.railHandleSize)
            .background {
                Circle()
                    .fill(isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Material.ultraThin))
                    .overlay(Circle().stroke(.quaternary))
                    .shadow(color: .black.opacity(0.18), radius: isDragging ? 6 : 3, y: 1)
            }
            .scaleEffect(isDragging ? 1.1 : 1)
            .accessibilityLabel("Scroll the page")
            .accessibilityHint("Drag up or down to move through the episode")
    }

    /// Where the page can actually be sent: its two ends, and every transcript line in
    /// between — those are the only things on it with an id to scroll to. The top of the
    /// rail is the top of the page rather than the first line, since the artwork and the
    /// details sit above the text.
    private func scroll(to fraction: Double, proxy: ScrollViewProxy) {
        let lines = transcript.lines
        guard !lines.isEmpty else {
            proxy.scrollTo(fraction < 0.5 ? Self.topAnchor : Self.bottomAnchor, anchor: fraction < 0.5 ? .top : .bottom)
            return
        }
        guard fraction > 0.02 else {
            proxy.scrollTo(Self.topAnchor, anchor: .top)
            return
        }
        let index = Int((Double(lines.count - 1) * fraction).rounded())
        proxy.scrollTo(lines[min(max(index, 0), lines.count - 1)].start, anchor: .top)
    }

    private func showRail() {
        isRailShowing = true
        scrollTick &+= 1
    }

    /// Watches the page go by: how far down it is, how long it is, and how much of it fits.
    /// One probe behind the whole content, rather than the transport's — that one stopped
    /// being a useful signal the moment it scrolled off the top.
    private var scrollProbe: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(Self.scrollSpace))
            Color.clear
                .onChange(of: frame.minY, initial: true) { previous, minY in
                    contentHeight = frame.height
                    let scrollable = max(frame.height - viewportHeight, 1)
                    scrollFraction = min(max(-minY / scrollable, 0), 1)
                    if previous != minY { showRail() }
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
