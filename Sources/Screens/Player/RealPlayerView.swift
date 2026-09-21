import SwiftUI

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingUpNext = false
    @State private var showingAddToPlaylist = false
    @State private var bookmarks: [Bookmark] = []
    /// The mark just made, lit for a moment so the jump to Notes lands on something the
    /// eye can find.
    @State private var highlightedBookmark: String?
    /// How far the page has been pulled past its own top, so it can shrink under the
    /// finger on the way out instead of just vanishing at the threshold.
    @State private var pullDown: CGFloat = 0
    @State private var isDismissing = false
    @State private var artist: Artist?
    /// Whether the transcript is following playback. Off until asked for: the page opens
    /// at the transport, and text that scrolls itself the moment you arrive takes the
    /// controls out from under your thumb. Any scroll of your own turns it off again.
    @State private var isFollowingTranscript = false
    /// Whether the big transport has scrolled out of sight. The docked bar is a stand-in
    /// for it, so showing both at once is just clutter.
    @State private var isTransportOffscreen = false
    /// Held rather than implicit, so the bar at the bottom knows whether it's standing on
    /// the player itself or on a page pushed from it — and can pop back rather than
    /// scroll.
    @State private var path: [PlayerRoute] = []

    private static let scrollSpace = "player.scroll"
    private static let topAnchor = "player.top"
    private static let transcriptAnchor = "player.transcript"
    private static let notesAnchor = "player.notes"
    /// How far past the top the page has to come before it goes away. Read off the scroll
    /// view's overscroll, which rubber-bands: the finger travels two to three times this,
    /// so it's well clear of the idle bounce at the top of a long page without asking for
    /// a stroke longer than the screen.
    private static let pullToDismiss: CGFloat = 70
    /// Read, never observed. A running transcription republishes several times a second,
    /// and observing it here redrew the artwork, the transport and the whole details card
    /// along with the text — which is what made the page flash while transcribing. The
    /// transcript pane does its own observing, so only the text redraws.
    private var transcript: TranscriptRunner { TranscriptRunner.shared }
    @State private var album: Album?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let bookmarkStore = BookmarkStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        // The inset sits on the stack rather than on each destination: pages pushed from
        // a pushed page — the browser walking into a subfolder — use plain links of their
        // own, and only a stack-level inset reaches those too. Empty at the root, which
        // has its own rule: no bar while the real transport is still on screen.
        NavigationStack(path: $path) {
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
                            // The transcript is the long part — forty minutes of speech
                            // is hundreds of lines, and the system indicator gives it a
                            // few points of travel.
                            .scrollHandle(
                                ids: transcript.lines.map { AnyHashable($0.start) },
                                proxy: proxy,
                                label: { index in
                                    let lines = transcript.lines
                                    guard index < lines.count else { return "" }
                                    return Scrubber.formatted(lines[index].start)
                                }
                            )
                            // Pinned: the page is now arbitrarily long, and the transport
                            // shouldn't be a scroll away at the bottom of a 40-minute
                            // transcript.
                            .safeAreaInset(edge: .bottom) {
                                if isTransportOffscreen {
                                    bottomBar(proxy).transition(.move(edge: .bottom))
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: isTransportOffscreen)
                            .navigationDestination(for: PlayerRoute.self) { route in
                                destination(route)
                            }
                            .task(id: track.id) {
                                artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
                                album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
                                refreshBookmarks(track)
                            }
                            .onReceive(NotificationCenter.default.publisher(for: .bookmarksDidChange)) { _ in
                                refreshBookmarks(track)
                            }
                    } else {
                        ContentUnavailableView("Nothing playing", systemImage: "mic.slash")
                    }
                }
                .background(Color.appBackground.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // The bar has a background of its own rather than floating clear over the
                // artwork: the page opens scrolled to the top, where a transparent bar put
                // "Now Playing" and the close chevron straight onto the picture.
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.appBackground, for: .navigationBar)
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
        // On the stack, so it reaches pages pushed from pushed pages too — the browser
        // walks into subfolders with plain links of its own, and a per-destination inset
        // never saw those.
        .safeAreaInset(edge: .bottom) { pushedPageBar }
        // Put the card down by pulling the page past its own top, which the scroll view
        // reports as overscroll. It shrinks as it goes, so the pull is answered before the
        // threshold rather than at it.
        .scaleEffect(1 - min(pullDown, Self.pullToDismiss) / 1600, anchor: .center)
        .animation(.interactiveSpring(response: 0.3), value: pullDown)
    }

    /// Split out of `body` purely so the type-checker can cope — it timed out once the
    /// transcript pane grew a binding and the page grew an overlay.
    private func page(for track: Track, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // No gesture of its own. A `DragGesture` here took the whole area away
                // from the scroll view — dragging up on the artwork, the most natural way
                // to reach the details and the transcript, did nothing at all. Putting the
                // card down is the overscroll pull, which the scroll view reports without
                // having to be fought for.
                VStack(spacing: 20) {
                    artwork(for: track)
                    titles(for: track)
                }
                Scrubber(currentTime: engine.currentTime, duration: engine.duration) { engine.seek(to: $0) }
                    .padding(.horizontal)
                transport(for: track, proxy: proxy)
                    .background { transportVisibilityProbe }
                queueControls(proxy)
                if let lastError = engine.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                EpisodeDetailsPane(playingTrack: track)

                NotesPane(
                    bookmarks: bookmarks,
                    highlighted: highlightedBookmark,
                    onAdd: { addBookmark(to: track, proxy: proxy) },
                    onPlay: { engine.seek(to: $0.position) },
                    onChange: { refreshBookmarks(track) }
                )
                .padding(.horizontal)
                .id(Self.notesAnchor)

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
        // Square and whole, the way every music player shows a cover: a 220pt band cropped
        // the top and bottom off pictures that are square to begin with, and nothing is
        // drawn over it — the title and speaker have their own line underneath.
        ArtworkTile(track: track, cornerRadius: 16, symbolSize: 64)
            .aspectRatio(1, contentMode: .fit)
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
            // No path here. It's what tells two identically-tagged episodes apart, which
            // matters in a *list* of them — under the title of the one already playing it
            // answers nothing, and it's the widest, least readable line on the page. The
            // Episode card's File rows carry it for the times you do want it.
            // Tapping either jumps to that speaker's/album's own page — same
            // destinations as tapping through from Home, just reachable from
            // whatever's currently playing too. One line rather than stacked,
            // since together they're still just a single subtitle.
            HStack(spacing: 12) {
                if let artist {
                    NavigationLink(value: PlayerRoute.speaker(artist.id)) {
                        Text("Speaker: \(artist.name)")
                    }
                }
                if let album {
                    NavigationLink(value: PlayerRoute.album(album.id)) {
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

    /// Favourite and "add to a playlist" flank the transport: both are things you do
    /// *about the episode you're hearing*, and both are one tap with nothing to read.
    /// Bookmarking moved out of this row — see `queueControls` — because marking a moment
    /// is the start of writing a note, and the note lives further down the page.
    private func transport(for track: Track, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 28) {
            Button {
                toggleFavorite(track)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(track.isFavorite ? AnyShapeStyle(Color.pink) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            }
            .accessibilityLabel(track.isFavorite ? "Remove from favourites" : "Add to favourites")

            // The bar-and-triangle skip glyph, not the double arrowhead: two arrowheads
            // read as rewind — hold to scrub — and these move to another episode.
            Button { engine.skipToPrevious() } label: { Image(systemName: "backward.end.fill").font(.title) }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { engine.skipToNext() } label: { Image(systemName: "forward.end.fill").font(.title) }

            Button {
                showingAddToPlaylist = true
            } label: {
                Image(systemName: "text.badge.plus").font(.title3)
            }
            .accessibilityLabel("Add to a playlist")
        }
    }

    /// The list actions and the way down to the text, under the transport where the rest
    /// of the controls are — they used to be a menu in the top-left corner, which is
    /// nowhere near the thumb and hid the queue's length.
    ///
    /// **"Up Next", not "Chapters".** This button opens `UpNextView`, and the queue behind
    /// it is whatever was playing from — one album's worth when you started there, the
    /// whole library when you didn't. Calling that a chapter count asserted a relationship
    /// that usually isn't true, and said so most loudly when it was most wrong: a
    /// twenty-minute episode announcing 1,469 chapters. The sheet has always been titled
    /// Up Next; the button now agrees with it. Moving between files by swiping the artwork
    /// is still the "turn the page" gesture — that one really is about this book.
    ///
    /// "Transcript" rather than lyrics, subtitles or captions: lyrics are for songs, and
    /// subtitles are text laid over a picture. It's the word the rest of the app uses, for
    /// the heading, the files beside the audio and what travels in a backup.
    private func queueControls(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button { showingUpNext = true } label: {
                Label("Up Next", systemImage: "list.bullet")
                    .pillLabel()
            }
            // Takes the page to the marks rather than making one: the button that
            // *creates* a mark lives in that section, where what it made is visible. A
            // create button up here made marks nobody could find.
            Button {
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.notesAnchor, anchor: .top) }
            } label: {
                Label("Bookmarks", systemImage: bookmarks.isEmpty ? "bookmark" : "bookmark.fill")
                    .pillLabel()
            }
            // The details card sits between the transport and the text, so on an episode
            // with a transcript this saves a long scroll past everything you already know.
            Button {
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.transcriptAnchor, anchor: .top) }
            } label: {
                Label("Transcript", systemImage: "captions.bubble")
                    .pillLabel()
            }
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        // Inset to the same margin as the Episode card below it. Left full-bleed, three
        // capsules ran wider than every other component on the page and read as a
        // different screen's worth of controls sitting on top of this one.
        .padding(.horizontal)
    }

    private func toggleFavorite(_ track: Track) {
        try? trackStore.setFavorite(id: track.id, isFavorite: !track.isFavorite)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Saves the mark and then shows it: the page goes to Notes, the new row lights up,
    /// and its pencil is the way in to saying why. Nothing is asked for at the moment of
    /// marking — a dialog over the thing you're listening to is how a mark gets made too
    /// late.
    private func addBookmark(to track: Track, proxy: ScrollViewProxy) {
        // The line being spoken travels with the mark: what was said there is the reason
        // it was marked, and a re-transcribe shouldn't be able to rewrite that.
        let spoken = transcript.currentLine(at: engine.currentTime)?.text
        guard let saved = try? bookmarkStore.add(
            trackID: track.id, positionMs: Int(engine.currentTime * 1000), transcriptText: spoken
        ) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        NotificationCenter.default.post(name: .bookmarksDidChange, object: nil)

        refreshBookmarks(track)
        isFollowingTranscript = false
        highlightedBookmark = saved.id
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(saved.id, anchor: .center) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard highlightedBookmark == saved.id else { return }
            withAnimation(.easeInOut(duration: 0.4)) { highlightedBookmark = nil }
        }
    }

    private func refreshBookmarks(_ track: Track) {
        bookmarks = (try? bookmarkStore.all(forTrack: track.id)) ?? []
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
    /// back to the top to stop playback — tapping the bar is the way back up.
    @ViewBuilder
    private func destination(_ route: PlayerRoute) -> some View {
        switch route {
        case .speaker(let id):
            if let speaker = (try? libraryStore.artist(id: id)) ?? nil {
                SpeakerDetailView(speaker: speaker)
            }
        case .album(let id):
            if let album = (try? libraryStore.album(id: id)) ?? nil {
                AlbumDetailView(album: album)
            }
        case .browse(let providerID, let folder, let highlight):
            if let record = (try? providerStore.all())?.first(where: { $0.id == providerID }) {
                RemoteBrowserView(
                    record: record, folder: folder,
                    title: folder.map { ($0 as NSString).lastPathComponent },
                    highlight: highlight, viewModel: SettingsViewModel()
                )
            }
        }
    }

    /// The same bar, on a page pushed from the player. Tapping it goes back to what's
    /// playing — there's no transport on this page to scroll up to.
    @ViewBuilder
    private var pushedPageBar: some View {
        if !path.isEmpty {
            VStack(spacing: 0) {
                ProgressView(value: engine.duration > 0 ? min(engine.currentTime / engine.duration, 1) : 0)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)

                NowPlayingBarContent(
                    track: engine.currentTrack,
                    artistName: artist?.name,
                    albumName: album?.name,
                    subtitle: "\(Scrubber.formatted(engine.currentTime)) / \(Scrubber.formatted(engine.duration))",
                    isPlaying: engine.isPlaying,
                    onTogglePlay: { engine.togglePlayPause() },
                    onTapBar: { path.removeAll() }
                )
            }
            .background(.ultraThinMaterial)
        }
    }

    private func bottomBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            ProgressView(value: engine.duration > 0 ? min(engine.currentTime / engine.duration, 1) : 0)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)

            NowPlayingBarContent(
                track: engine.currentTrack,
                artistName: artist?.name,
                albumName: album?.name,
                subtitle: "\(Scrubber.formatted(engine.currentTime)) / \(Scrubber.formatted(engine.duration))",
                isPlaying: engine.isPlaying,
                onTogglePlay: { engine.togglePlayPause() },
                // Already on this page, so the bar's job is the way back up rather than
                // a screen transition to where you already are.
                onTapBar: {
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
            )
        }
        .background(.ultraThinMaterial)
    }
}

/// The bar at the bottom of the screen, wherever it appears: over Home as the way into
/// whatever is playing, and docked on the player itself as the way back to the top.
///
/// Three lines because that's what the question "what am I listening to?" actually takes —
/// the episode, who is speaking, and which collection it came from. One line of title over
/// a filename answered none of them.
///
/// **Play/pause is the only button, and it's on the right.** Skip was the far-right
/// control, which put the destructive-ish action under the thumb that reaches furthest and
/// left pause — the thing anyone actually reaches for in a hurry — on the far side.
struct NowPlayingBarContent: View {
    let track: Track?
    let artistName: String?
    let albumName: String?
    /// The second line under the title: a timecode on the player, the file elsewhere.
    var subtitle: String?
    let isPlaying: Bool
    let onTogglePlay: () -> Void
    let onTapBar: () -> Void

    /// Bigger than the `.title2` it was: it's the one control on the bar and the one
    /// reached for in a hurry — often without looking — so it's sized for that rather
    /// than to match the text beside it. `@ScaledMetric` keeps it growing with Dynamic
    /// Type the way a text style would.
    @ScaledMetric(relativeTo: .title2) private var glyphSize: CGFloat = 26

    var body: some View {
        if let track {
            HStack(spacing: 12) {
                Button(action: onTapBar) {
                    HStack(spacing: 12) {
                        ArtworkTile(track: track, cornerRadius: 7, symbolSize: 16)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let context = [artistName, albumName].compactMap({ $0?.nilIfEmpty }).nilIfEmpty {
                                Text(context.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let subtitle {
                                Text(subtitle)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onTogglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: glyphSize))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            // Less under than over: the home indicator already holds a band of clear
            // space below the bar, and 8pt of padding on top of it read as the bar
            // floating off the bottom of the screen.
            .padding(.top, 8)
            .padding(.bottom, 2)
        }
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

/// Drives itself from a locally-held drag position while the user's finger is down, so
/// `PlaybackEngine`'s periodic `currentTime` publishing (every 0.5s) can't yank the thumb
/// back mid-drag. A zero-distance drag gesture also means tapping anywhere on the track
/// jumps straight there, not just dragging the thumb.
/// Where you are in the episode, and the way to move it.
///
/// **It has to be taken hold of first.** A bare drag gesture across the width of the
/// screen is a trap on a page you scroll: a thumb brushing the bar on the way past threw
/// away the place you were listening to, with nothing to undo it. A press of a moment
/// arms it — the bar thickens, the handle appears under the finger and the app taps back
/// — and only then does sliding move anything. A stroke that keeps moving never arms it,
/// so the page scrolls as it should.
///
/// The handle is hidden until then, the way every music player does it: a dot sitting on
/// the line is an invitation to drag, and this one shouldn't be taken up by accident.
struct Scrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    /// Long enough not to fire on a thumb passing through, short enough that reaching for
    /// it on purpose doesn't feel like waiting.
    private static let holdToScrub = 0.22

    @State private var isScrubbing = false
    @State private var dragTime: TimeInterval = 0

    private var displayedTime: TimeInterval { isScrubbing ? dragTime : currentTime }
    private var progress: Double { duration > 0 ? min(max(displayedTime / duration, 0), 1) : 0 }
    private var trackHeight: CGFloat { isScrubbing ? 7 : 4 }
    private var knobSize: CGFloat { isScrubbing ? 18 : 0 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: trackHeight)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: trackHeight)
                    Circle().fill(Color.accentColor)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(radius: isScrubbing ? 3 : 0)
                        .offset(x: geo.size.width * progress - knobSize / 2)
                }
                .animation(.easeOut(duration: 0.15), value: isScrubbing)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(scrub(width: geo.size.width))
            }
            .frame(height: 24)
            HStack {
                Text(Self.formatted(displayedTime))
                    .foregroundStyle(isScrubbing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                Spacer()
                Text(Self.formatted(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Hold, then slide. `maximumDistance` is what lets a scroll through the bar fail the
    /// press instead of arming it.
    private func scrub(width: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: Self.holdToScrub, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    take(hold: true)
                case .second(true, let drag):
                    take(hold: true)
                    if let drag { dragTime = time(atX: drag.location.x, width: width) }
                default:
                    break
                }
            }
            .onEnded { value in
                guard isScrubbing else { return }
                if case .second(true, let drag?) = value {
                    dragTime = time(atX: drag.location.x, width: width)
                }
                onSeek(dragTime)
                isScrubbing = false
            }
    }

    /// Arms once per hold: the gesture reports `.first`/`.second` repeatedly, and the
    /// starting time must not be re-read after the finger has begun to move it.
    private func take(hold: Bool) {
        guard hold, !isScrubbing else { return }
        dragTime = currentTime
        isScrubbing = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
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

private extension View {
    /// Keeps a row of pills even: equal widths, one line each, shrinking the text rather
    /// than wrapping it. Three pills whose labels are different lengths otherwise give
    /// three different widths — and any one that wraps grows taller than the rest, which
    /// is what left the middle of this row standing proud of the other two.
    func pillLabel() -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
    }
}

/// Where the player can push to. A route rather than a view, so the stack has a path the
/// docked bar can read and pop.
enum PlayerRoute: Hashable {
    case speaker(String)
    case album(String)
    /// The bucket browser, opened at the folder this episode sits in. `highlight` is the
    /// file to scroll to and mark once it's there.
    case browse(providerID: String, folder: String?, highlight: String?)
}
