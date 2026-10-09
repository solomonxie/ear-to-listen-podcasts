import SwiftUI
import UIKit

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    /// Closing is a flag on the engine now, not `@Environment(\.dismiss)`: the page is a
    /// sibling view rather than a presentation, so there is nothing to dismiss — see
    /// `ContentView`.
    private func close() { PlaybackEngine.shared.isPresentingPlayer = false }
    @State private var showingUpNext = false
    @State private var bookmarks: [Bookmark] = []
    /// The mark just made, lit for a moment so the jump to Notes lands on something the
    /// eye can find.
    @State private var highlightedBookmark: String?
    /// Where the seek bar is on screen. The bar runs the full width of the page, so its
    /// left end sits inside the strip the back swipe watches — and a seek started there
    /// used to slide the whole player off instead of moving the playhead.
    @State private var seekBarArea: CGRect = .zero
    /// The same, for the bottom bar's seek line.
    @State private var barSeekArea: CGRect = .zero
    @State private var artist: Artist?
    /// Whether the transcript is following playback. Off until asked for: the page opens
    /// at the transport, and text that scrolls itself the moment you arrive takes the
    /// controls out from under your thumb. Any scroll of your own turns it off again.
    @State private var isFollowingTranscript = false
    /// Whether the big transport has scrolled out of sight. The docked bar is a stand-in
    /// for it, so showing both at once is just clutter.
    @State private var isTransportOffscreen = false
    /// Set by the transcript pane while a line is open for correction. Everything that sits
    /// over the bottom of the page gets out of the way for it.
    @State private var isEditingLine = false
    /// Held rather than implicit, so the bar at the bottom knows whether it's standing on
    /// the player itself or on a page pushed from it — and can pop back rather than
    /// scroll.
    @State private var path: [PlayerRoute] = []
    /// Bumped to send the page to Notes from outside the page's own scroll — a long press
    /// on the bar's bookmark, here or from Home.
    @State private var notesRequests: Int
    /// The same, for the bar's Top and Follow pressed somewhere other than this page.
    @State private var topRequests: Int
    @State private var followRequests: Int

    init(opensAt landing: PlayerLanding? = nil) {
        _notesRequests = State(initialValue: landing == .notes ? 1 : 0)
        _followRequests = State(initialValue: landing == .following ? 1 : 0)
        _topRequests = State(initialValue: landing == .top ? 1 : 0)
    }

    private static let scrollSpace = "player.scroll"
    private static let topAnchor = "player.top"
    private static let transcriptAnchor = "player.transcript"
    private static let notesAnchor = "player.notes"

    /// What the grab handle can reach above the transcript, in the order they appear on
    /// the page. Named rather than numbered in the bubble: "Top" says where a drag is
    /// about to land, and a timecode wouldn't — none of these three is a moment.
    private static let pageAnchors = [topAnchor, notesAnchor, transcriptAnchor]
    private static let pageAnchorLabels = ["Top", "Notes", "Text"]
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
                            // The transcript is the long part — forty minutes of speech
                            // is hundreds of lines, and the system indicator gives it a
                            // few points of travel.
                            // The page's own three landmarks come first, then every
                            // spoken line. Fed the transcript alone, the handle's top of
                            // travel was the transcript's first line — the artwork, the
                            // transport and the details sat above it with no way to drag
                            // back to them, which reads as a scrollbar that can't reach
                            // the top of its own page.
                            .scrollHandle(
                                ids: Self.pageAnchors.map(AnyHashable.init)
                                    + transcript.lines.map { AnyHashable($0.start) },
                                proxy: proxy,
                                label: { index in
                                    guard index >= Self.pageAnchors.count else {
                                        return Self.pageAnchorLabels[index]
                                    }
                                    let lines = transcript.lines
                                    let line = index - Self.pageAnchors.count
                                    guard line < lines.count else { return "" }
                                    return SeekBar.formatted(lines[line].start)
                                }
                            )
                            // Pinned: the page is now arbitrarily long, and the transport
                            // shouldn't be a scroll away at the bottom of a 40-minute
                            // transcript.
                            // Not while a line is being corrected: it is an inset rather than
                            // an overlay, so it doesn't cover the field — but it takes a bar's
                            // height out of a screen the keyboard has already taken a third
                            // of, and editing pauses playback anyway, so a transport is the
                            // one thing certainly not wanted.
                            .safeAreaInset(edge: .bottom) {
                                if isTransportOffscreen, !isEditingLine {
                                    bottomBar(proxy).transition(.move(edge: .bottom))
                                }
                            }
                            .animation(.easeInOut(duration: 0.2), value: isTransportOffscreen)
                            .animation(.easeInOut(duration: 0.2), value: isEditingLine)
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
                            // Waits out the page sliding in, or a pushed page popping.
                            .task(id: notesRequests) {
                                guard notesRequests > 0 else { return }
                                try? await Task.sleep(for: .milliseconds(350))
                                showBookmarks(proxy)
                            }
                            .task(id: topRequests) {
                                guard topRequests > 0 else { return }
                                try? await Task.sleep(for: .milliseconds(350))
                                scrollToTop(proxy)
                            }
                            .task(id: followRequests) {
                                guard followRequests > 0 else { return }
                                // Longer: the transcript may still be loading on a fresh open.
                                try? await Task.sleep(for: .milliseconds(600))
                                follow(proxy)
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
                    // A page you go back from, not a card you put down. The arrow points the
                    // way the gesture goes, and both leave the same way — which is the point
                    // of the change: everywhere else in this app, back is left.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { close() } label: {
                            Label("Back", systemImage: "chevron.left").font(.body.weight(.semibold))
                        }
                    }
                    // Tapping the title goes back to the top, as it does in every iOS app
                    // whose content runs past the fold.
                    // Marked automatically at the end of playback; this is for the ones
                    // you're done with before then, or want back in the running.
                    ToolbarItem(placement: .topBarTrailing) {
                        if let track = engine.currentTrack {
                            Button { toggleListened(track) } label: {
                                Image(systemName: track.listenedAt == nil ? "checkmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(track.listenedAt == nil ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(Color.green))
                            }
                            .accessibilityLabel(track.listenedAt == nil ? "Mark as listened" : "Mark as not listened")
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        Button {
                            isFollowingTranscript = false
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                        } label: {
                            VStack(spacing: 0) {
                                Text(engine.currentTrack?.title ?? "").font(.subheadline.weight(.semibold))
                                if let name = artist?.name, !name.isEmpty {
                                    Text(name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .sheet(isPresented: $showingUpNext) {
                    UpNextView()
                }
            }
        }
        // On the stack, so it reaches pages pushed from pushed pages too — the browser
        // walks into subfolders with plain links of its own, and a per-destination inset
        // never saw those.
        .dockedBottomBar { pushedPageBar }
        // Stood down the moment anything is pushed: a pushed page has the system's own
        // back swipe, and a page that can't be swiped back from is a page with no way out
        // for anyone who doesn't look for the ‹.
        .swipeToGoBack(
            canBegin: { path.isEmpty && !seekBarArea.contains($0) && !barSeekArea.contains($0) }, perform: close
        )
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
                SeekBar(
                    currentTime: engine.currentTime, duration: engine.duration,
                    area: $seekBarArea
                ) { engine.seek(to: $0) }
                    .padding(.horizontal, 36)
                transport(for: track, proxy: proxy)
                    .background { transportVisibilityProbe }
                queueControls(proxy)
                if let lastError = engine.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                EpisodeDetailsPane(playingTrack: track)

                NotesPane(
                    bookmarks: bookmarks,
                    youTubeID: { _ in track.youTubeID },
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
                    spokenStart: transcript.currentLine(at: engine.currentTime)?.start,
                    scrollProxy: proxy,
                    isFollowing: $isFollowingTranscript,
                    onFollow: { follow(proxy) },
                    onPause: { if engine.isPlaying { engine.pause() } },
                    isEditingLine: $isEditingLine
                ) { time in
                    engine.seek(to: time)
                    // Picking a line means "read along from here", so it plays from there.
                    // A seek that left a paused page paused sent the reader back to the
                    // transport to hear the line they had just chosen.
                    if !engine.isPlaying { engine.resume() }
                }

            }
            .padding(.vertical)
        }
        .coordinateSpace(name: Self.scrollSpace)
        // The page draws its own bar below; the system's would sit a few points
        // beside it, two indicators of different lengths down the same edge.
        .scrollIndicators(.hidden)
        // The details are edited in place, so a keyboard can be up over a page that
        // scrolls — dragging it away is how everyone expects to be rid of it.
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func artwork(for track: Track) -> some View {
        if track.isVideoOnly, let videoID = track.youTubeID {
            video(videoID, track: track)
        } else {
            cover(for: track)
        }
    }

    /// The video where the cover would be, 16:9 and nearly full width. It scrolls away
    /// with the page like the cover does — reading the transcript doesn't need it in view,
    /// and it keeps playing out of sight.
    ///
    /// The thumbnail stands in until the video is actually playing, and stays when YouTube
    /// won't play it here — its error screen, a sign-in wall nobody can get past from
    /// inside an app, is kept loaded underneath but never shown.
    private func video(_ videoID: String, track: Track) -> some View {
        VStack(spacing: 8) {
            ZStack {
                YouTubePlayerView(embed: engine.youTube)
                    .opacity(engine.youTubeDisplay == .showing ? 1 : 0)
                if engine.youTubeDisplay != .showing {
                    ArtworkTile(track: track, cornerRadius: 0, symbolSize: 44)
                        .overlay {
                            if engine.youTubeDisplay == .loading { ProgressView().tint(.white) }
                        }
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if engine.youTubeDisplay == .blocked {
                Text("YouTube won't play this one here. Play still keeps time for your marks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Link(destination: YouTubeVideo.watchURL(id: videoID, at: engine.currentTime)) {
                Label("Open in YouTube at \(SeekBar.formatted(engine.currentTime))", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .id(Self.topAnchor)
    }

    private func cover(for track: Track) -> some View {
        // Square and whole, the way every music player shows a cover: a 220pt band cropped
        // the top and bottom off pictures that are square to begin with, and nothing is
        // drawn over it — the title and speaker have their own line underneath.
        //
        // Inset, not full width: edge to edge its corners crowded the screen's own rounded
        // corners and the cover took most of the first screen. About 70% of the width,
        // capped for bigger phones, with room above it.
        ArtworkTile(track: track, cornerRadius: 14, symbolSize: 56)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300)
            .padding(.horizontal, 56)
            .padding(.top, 12)
            .frame(maxWidth: .infinity)
            .id(Self.topAnchor)
            // The big empty area at the top of the page doubles as "I'm done typing".
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The marks, without making one — the pill under the transport.
    ///
    /// Following goes off for the same reason Back to top turns it off: this is a move made
    /// to read something, and a page that scrolls itself is a page you can't read.
    private func showBookmarks(_ proxy: ScrollViewProxy) {
        isFollowingTranscript = false
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.notesAnchor, anchor: .top) }
    }

    /// Takes the page to the text — and to the *line being spoken*, following on, so it
    /// keeps up from there.
    ///
    /// Landing on the section heading and stopping was only right for an episode nobody
    /// had started. Forty minutes in it put the reader at the top of forty minutes of
    /// transcript, with the part they were actually listening to somewhere below, to be
    /// found by hand — while the page sat there scrolling itself away from them if
    /// following happened to be on.
    ///
    /// The heading is still the answer when there is no line to jump to: at 0 nothing has
    /// been spoken yet, and a part-transcribed episode played past the end of its own text
    /// has nothing at that second either.
    private func showTranscript(_ proxy: ScrollViewProxy) {
        guard engine.currentTime > 0, transcript.currentLine(at: engine.currentTime) != nil else {
            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.transcriptAnchor, anchor: .top) }
            return
        }
        follow(proxy)
    }

    /// see `isFollowingTranscript`.
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        isFollowingTranscript = false
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
    }

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

    /// Favourite and bookmark flank the transport: both are things you do *because of
    /// what you're hearing right now*, and both are one tap with nothing to read. Moving
    /// between episodes isn't on this row at all any more; Up Next, right below it, is
    /// the list that does it, and adding to a playlist — a decision about the episode,
    /// not about this second of it — moved to the Episode card's Playlists row.
    ///
    /// **The mark here doesn't take you to it.** You press it while listening, and being
    /// thrown down the page to the row it just made is the interruption the mark was
    /// supposed to avoid. The [ Bookmarks ] pill below is the other half: it goes to the
    /// marks without making one.
    private func transport(for track: Track, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            transportButton(track.isFavorite ? "Remove from favourites" : "Add to favourites") {
                toggleFavorite(track)
            } glyph: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(track.isFavorite ? AnyShapeStyle(Color.pink) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            }

            // Ten seconds, not the next episode. Spoken audio is missed a sentence at a
            // time — "what did they just say" is what anyone reaches for mid-episode,
            // while moving to another one is a decision made from Up Next, a tap below.
            // The arrow-round-a-10 glyph says the interval, so neither needs a label.
            transportButton("Back ten seconds") { engine.skip(by: -10) } glyph: {
                Image(systemName: "gobackward.10")
            }
            transportButton(engine.isPlaying ? "Pause" : "Play", glyphSize: 50) {
                engine.togglePlayPause()
            } glyph: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            }
            transportButton("Forward ten seconds") { engine.skip(by: 10) } glyph: {
                Image(systemName: "goforward.10")
            }

            // Marks and stays put: nothing is asked at the moment of marking — a dialog
            // over what you're listening to is how a mark gets made too late — and the
            // note is written afterwards, in the row itself, whenever you go looking.
            //
            // The count in the corner is the whole receipt. A button that goes nowhere
            // and asks nothing otherwise looks like it did nothing, and the number going
            // up is both "that worked" and "this is your fourth" — which is the thing
            // worth knowing before you mark the same minute twice.
            transportButton("Bookmark this moment") { markMoment(track) } glyph: {
                Image(systemName: "bookmark.fill")
                    .symbolEffect(.bounce, value: bookmarks.count)
                    .overlay(alignment: .topTrailing) { MarkCountBadge(count: bookmarks.count) }
            }
            .accessibilityValue(bookmarks.isEmpty ? "No marks yet" : "\(bookmarks.count) marks")
        }
        .padding(.horizontal, 8)
    }

    /// One size for all five, each in an equal share of the width.
    ///
    /// They used to be three sizes — a 56pt play circle between two `.title` skips, with a
    /// `.title3` heart and bookmark on the ends — and the small outer two were the ones
    /// being missed. A 20pt glyph is a 20pt target: the thumb arrives from below, covers
    /// the whole row, and lands on whichever neighbour it overlapped. Equal columns of
    /// equal height mean every button is the same size as the gap around it, so a tap that
    /// is a few points off still hits what it was aimed at.
    ///
    /// **The targets are equal; the glyphs are not.** Play is drawn half as big again as
    /// the rest, because a transport where every control looks alike is a row you have to
    /// read before you can use it — the big circle in the middle is how the thumb finds
    /// the one button it presses most, without looking. What made the old row miss was
    /// never the size of the play circle, it was the 20pt heart and bookmark on the ends,
    /// and those are gone: the column is what's tapped, and every column is the same.
    private func transportButton<Glyph: View>(
        _ label: LocalizedStringKey, glyphSize: CGFloat = 30,
        action: @escaping () -> Void, @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        Button(action: action) {
            glyph()
                .font(.system(size: glyphSize))
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
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
            // The details card sits between the transport and the text, so on an episode
            // with a transcript this saves a long scroll past everything you already know.
            Button {
                showTranscript(proxy)
            } label: {
                Label("Transcript", systemImage: "captions.bubble")
                    .pillLabel()
            }
            // Goes to the marks without making one — the transport's bookmark, a hand's
            // width above this row, is what makes them.
            Button {
                showBookmarks(proxy)
            } label: {
                Label("Bookmarks", systemImage: bookmarks.isEmpty ? "bookmark" : "bookmark.fill")
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

    /// The glyph changes on the tap, not after the library has reloaded: that round trip
    /// waited out a debounce and then queued behind Home's whole-library refresh on the
    /// one database connection — seconds before a checkmark went green.
    private func toggleListened(_ track: Track) {
        let listened = track.listenedAt == nil
        engine.showEdit(of: track.id) { $0.listenedAt = listened ? Date() : nil }
        let store = trackStore
        Task.detached(priority: .userInitiated) {
            try? store.setListened(ids: [track.id], listened: listened)
            await MainActor.run { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
        }
    }

    private func toggleFavorite(_ track: Track) {
        let isFavorite = !track.isFavorite
        engine.showEdit(of: track.id) { $0.isFavorite = isFavorite }
        let store = trackStore
        Task.detached(priority: .userInitiated) {
            try? store.setFavorite(id: track.id, isFavorite: isFavorite)
            await MainActor.run { NotificationCenter.default.post(name: .libraryDidChange, object: nil) }
        }
    }

    /// Marks and stays put. Nothing is asked for at the moment of marking — a dialog over
    /// the thing you're listening to is how a mark gets made too late — and the mark is
    /// left lit for whenever the Notes section is next reached.
    @discardableResult
    private func markMoment(_ track: Track) -> Bookmark? {
        guard let saved = MomentMark.add(to: track, at: engine.currentTime) else { return nil }
        refreshBookmarks(track)
        highlightedBookmark = saved.id
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard highlightedBookmark == saved.id else { return }
            withAnimation(.easeInOut(duration: 0.4)) { highlightedBookmark = nil }
        }
        return saved
    }

    /// Saves the mark and then shows it: the page goes to Notes, the new row lights up,
    /// and its pencil is the way in to saying why. Only for the button that already lives
    /// in Notes — pressed from deep inside the transcript, going to the mark means leaving
    /// the line that was worth marking.
    private func addBookmark(to track: Track, proxy: ScrollViewProxy) {
        guard let saved = markMoment(track) else { return }
        isFollowingTranscript = false
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(saved.id, anchor: .center) }
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
        case .term(let term):
            TermDetailView(term: term)
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
            NowPlayingBarContent(
                track: engine.currentTrack,
                currentTime: engine.currentTime,
                duration: engine.duration,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onSkipForward: { engine.skip(by: 10) },
                onTogglePlay: { engine.togglePlayPause() },
                bookmarkCount: bookmarks.count,
                onBookmark: { if let track = engine.currentTrack { markMoment(track) } },
                onShowBookmarks: {
                    path.removeAll()
                    notesRequests += 1
                },
                onTapBar: { path.removeAll() },
                onSeek: { engine.seek(to: $0) },
                onFollow: {
                    path.removeAll()
                    followRequests += 1
                }
            )
        }
    }

    private func bottomBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            NowPlayingBarContent(
                track: engine.currentTrack,
                currentTime: engine.currentTime,
                duration: engine.duration,
                isPlaying: engine.isPlaying,
                onSkipBack: { engine.skip(by: -10) },
                onSkipForward: { engine.skip(by: 10) },
                onTogglePlay: { engine.togglePlayPause() },
                bookmarkCount: bookmarks.count,
                onBookmark: { if let track = engine.currentTrack { markMoment(track) } },
                onShowBookmarks: { showBookmarks(proxy) },
                // Already on this page, so the bar's job is the way back up rather than
                // a screen transition to where you already are — and following goes off
                // with it. Leaving it on made the tap look
                // broken: the page went up and the next spoken line pulled it straight
                // back down to the transcript.
                onTapBar: {
                    isFollowingTranscript = false
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                },
                onSeek: { engine.seek(to: $0) },
                seekArea: $barSeekArea,
                isFollowing: isFollowingTranscript,
                onFollow: { if isFollowingTranscript { isFollowingTranscript = false } else { follow(proxy) } }
            )
        }
    }
}

/// The bar at the bottom of the screen, wherever it appears: over Home as the way into
/// whatever is playing, and docked on the player itself as the way back to the top.
///
/// Controls only — transcript, back 10s, play/pause, forward 10s, mark — with play in the middle where the
/// thumb finds it without looking. What's playing is named in the player's top bar, not
/// repeated here. Tapping anywhere else on the bar does the page's `onTapBar`.
/// Where the episode page lands when something outside it opens it.
enum PlayerLanding { case top, notes, following }

/// The bar's progress line, and a way to move it: drag along it to go anywhere in the
/// episode. Thin at rest; it thickens and shows the time under the finger while dragged.
/// A plain tap on the bar still opens the episode — the drag needs a few points of
/// movement before it takes over.
private struct BarSeekLine: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let area: Binding<CGRect>?
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max((isDragging ? dragTime : currentTime) / duration, 0), 1)
    }

    /// The hairline sits this far down a taller strip, so a finger landing just above it —
    /// where a finger aimed at a line on a bar's edge usually lands — still catches it.
    private static let reachAbove: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(Color.accentColor).frame(width: geo.size.width * progress)
            }
            .frame(height: isDragging ? 6 : 3)
            // A knob says the line can be moved.
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 16 : 10, height: isDragging ? 16 : 10)
                    .offset(x: geo.size.width * progress - (isDragging ? 8 : 5))
            }
            .animation(.easeOut(duration: 0.12), value: isDragging)
            .padding(.top, Self.reachAbove)
            .frame(maxHeight: .infinity, alignment: .top)
            // The whole strip catches the finger, not just the hairline.
            .contentShape(Rectangle())
            .gesture(drag(width: geo.size.width))
            .overlay(alignment: .top) {
                if isDragging {
                    Text("\(SeekBar.formatted(dragTime)) / \(SeekBar.formatted(duration))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .offset(y: -34)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: geo.frame(in: .global), initial: true) { area?.wrappedValue = $1 }
        }
        .frame(height: 18 + Self.reachAbove)
        // Drawn up over the page above, so the line stays on the bar's edge.
        .padding(.top, -Self.reachAbove)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(SeekBar.formatted(currentTime)) of \(SeekBar.formatted(duration))")
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                dragTime = time(atX: value.location.x, width: width)
            }
            .onEnded { value in
                dragTime = time(atX: value.location.x, width: width)
                isDragging = false
                onSeek(dragTime)
            }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(x / width, 0), 1) * duration
    }
}

struct NowPlayingBarContent: View {
    let track: Track?
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onTogglePlay: () -> Void
    let bookmarkCount: Int
    let onBookmark: () -> Void
    /// Long press on the bookmark: go to the marks rather than make one.
    let onShowBookmarks: () -> Void
    let onTapBar: () -> Void
    let onSeek: (TimeInterval) -> Void
    /// Where the bar's seek line is, for a back swipe to stand off.
    var seekArea: Binding<CGRect>? = nil
    var isFollowing = false
    let onFollow: () -> Void

    @ScaledMetric(relativeTo: .title2) private var glyphSize: CGFloat = 34
    @State private var marksMade = 0
    private static let buttonHeight: CGFloat = 62
    private static let homeIndicatorOverlap: CGFloat = 14

    var body: some View {
        if track != nil {
            VStack(spacing: 0) {
                BarSeekLine(currentTime: currentTime, duration: duration, area: seekArea, onSeek: onSeek)

                // No times beside them: the line above says where it is, and while it's
                // being dragged it says so in numbers. Each button takes an equal share of
                // the width, so they sit as far apart as the bar allows.
                HStack(spacing: 0) {
                    sideButton(
                        isFollowing ? "captions.bubble.fill" : "captions.bubble",
                        label: isFollowing ? "Stop following the transcript" : "Follow the transcript",
                        isOn: isFollowing, action: onFollow
                    )
                    barButton("gobackward.10", size: min(glyphSize + 2, 40), label: "Back ten seconds", action: onSkipBack)
                    barButton(isPlaying ? "pause.circle.fill" : "play.circle.fill", size: min(glyphSize + 24, 60),
                              label: isPlaying ? "Pause" : "Play", action: onTogglePlay)
                    barButton("goforward.10", size: min(glyphSize + 2, 40), label: "Forward ten seconds", action: onSkipForward)
                    bookmarkButton
                }
                .padding(.horizontal, 16)
                .padding(.top, -4)
                // Down into part of the home indicator's strip, which otherwise left a
                // band of empty bar under the buttons. The indicator itself stays clear.
                .padding(.bottom, -Self.homeIndicatorOverlap)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapBar)
            }
            .background(.ultraThinMaterial)
        }
    }

    /// A mark is a snapshot of the moment, so it lands like one: the screen flashes
    /// (`MarkFlash`), the glyph bounces, and the count rolls up.
    private var bookmarkButton: some View {
        Image(systemName: bookmarkCount > 0 ? "bookmark.fill" : "bookmark")
            .font(.system(size: min(glyphSize + 2, 38)))
            .symbolEffect(.bounce, value: marksMade)
            .overlay(alignment: .topTrailing) {
                MarkCountBadge(count: bookmarkCount, offset: CGSize(width: 12, height: -6))
            }
            .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                onBookmark()
                marksMade += 1
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onShowBookmarks()
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Bookmark this moment")
            .accessibilityValue(bookmarkCount == 0 ? "No marks yet" : "\(bookmarkCount) marks")
            .accessibilityAction { onBookmark() }
            .accessibilityAction(named: "Show bookmarks", onShowBookmarks)
    }

    /// Follow, at the left end — a page move rather than playback, so it sits back in grey
    /// and lights up only while it's on.
    private func sideButton(
        _ systemImage: String, label: LocalizedStringKey, isOn: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: min(glyphSize - 8, 24), weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func barButton(
        _ systemImage: String, size: CGFloat, label: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Where you are in the episode, and the way to move it.
///
/// **Touch it and it moves.** The handle sits on the line at all times, a tap anywhere on
/// the bar goes there, and a drag tracks the finger from the first frame. An earlier
/// version asked for a short hold first, to keep a stroke meant for the page from being
/// read as a seek; it cost every deliberate seek a wait, which is the wrong trade on the
/// one control this page exists for.
///
/// Drives itself from a locally-held drag position while the finger is down, so
/// `PlaybackEngine`'s periodic `currentTime` publishing (every 0.5s) can't yank the handle
/// back mid-drag.
///
/// It reports where it is on screen, because the page's left-edge back swipe overlaps its
/// left end. Without a hold there is no moment at which to raise a flag — the swipe has
/// already claimed the stroke by then — so the swipe keeps off the bar's rectangle
/// instead, decided at touch-down.
struct SeekBar: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    /// The bar's place in the window, for the back swipe to stand off.
    @Binding var area: CGRect
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var displayedTime: TimeInterval { isDragging ? dragTime : currentTime }
    private var progress: Double { duration > 0 ? min(max(displayedTime / duration, 0), 1) : 0 }
    private var trackHeight: CGFloat { isDragging ? 7 : 4 }
    /// Always shown, and grown under the finger: a dot on the line is what tells you the
    /// line can be dragged.
    private var knobSize: CGFloat { isDragging ? 18 : 12 }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: trackHeight)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: trackHeight)
                    Circle().fill(Color.accentColor)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(radius: isDragging ? 3 : 0)
                        .offset(x: geo.size.width * progress - knobSize / 2)
                }
                .animation(.easeOut(duration: 0.15), value: isDragging)
                .frame(maxHeight: .infinity, alignment: .center)
                // Taller than it looks, so the bar can be caught without aiming.
                .contentShape(Rectangle())
                .gesture(seekDrag(width: geo.size.width))
                .onChange(of: geo.frame(in: .global), initial: true) { area = $1 }
            }
            .frame(height: 32)
            HStack {
                Text(Self.formatted(displayedTime))
                    .foregroundStyle(isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                Spacer()
                Text(Self.formatted(duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Zero minimum distance: the first touch already moves the playhead, so a tap seeks
    /// and a drag needs no run-up.
    private func seekDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                dragTime = time(atX: value.location.x, width: width)
            }
            .onEnded { value in
                dragTime = time(atX: value.location.x, width: width)
                isDragging = false
                onSeek(dragTime)
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

/// The queue, whole — what's coming, what's playing, and what came before it.
///
/// It listed the queue flat and called the lot "Up Next", which was only true of the part
/// below the row with the speaker glyph on it. Half an album in, the sheet opened on the
/// first episode of the collection with no sign of which one was playing, and the episode
/// you'd just finished and wanted back looked like something scheduled to come.
///
/// Three headings say which part is which, and the sheet opens on the one playing rather
/// than at the top — the queue is as long as the collection it came from. An episode
/// opened on its own gets its whole collection as the queue (`PlaybackEngine`), so
/// track 14 has 1–13 above it here.
private struct UpNextView: View {
    @ObservedObject var engine = PlaybackEngine.shared

    private var currentIndex: Int? {
        guard let current = engine.currentTrack else { return nil }
        return engine.queue.firstIndex { $0.id == current.id }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let currentIndex {
                        // "Earlier", not "Played": these are the episodes before this one
                        // in the collection, and whether they were listened to is a
                        // different question this list can't answer.
                        section("Earlier", Array(engine.queue[..<currentIndex]), isPast: true)
                        section("Now Playing", [engine.queue[currentIndex]])
                        section("Coming Up", Array(engine.queue[(currentIndex + 1)...]))
                    } else {
                        section(nil, engine.queue)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.appBackground.ignoresSafeArea())
                .navigationTitle("Up Next")
                .navigationBarTitleDisplayMode(.inline)
                // Keyed on the queue too: an episode opened on its own gets its collection a
                // moment later, and the row has to be centred again once 1–13 land above it.
                // The wait is for the rows to lay out and the sheet to finish rising —
                // scrolled any sooner, the row isn't there yet and it's a no-op.
                .task(id: "\(engine.currentTrack?.id ?? "")|\(engine.queue.count)") {
                    try? await Task.sleep(for: .milliseconds(250))
                    scrollToCurrent(proxy)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = engine.currentTrack else { return }
        proxy.scrollTo(current.id, anchor: .center)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey?, _ tracks: [Track], isPast: Bool = false) -> some View {
        if !tracks.isEmpty {
            Section {
                ForEach(tracks) { row($0, isPast: isPast) }
            } header: {
                if let title { Text(title) }
            }
        }
    }

    /// Past rows are greyed, not disabled: behind you is still somewhere to go back to.
    private func row(_ track: Track, isPast: Bool) -> some View {
        Button {
            engine.play(track: track, queue: engine.queue)
        } label: {
            HStack {
                if track.id == engine.currentTrack?.id {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(isPast ? .secondary : .primary)
                    Text(TrackRow.fileName(for: track))
                        .font(.caption)
                        .foregroundStyle(isPast ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(track.id)
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
    /// A name or term the episode mentions — carried whole rather than by id, so the
    /// page it opens has a title before it has read anything.
    case term(Term)
    /// The bucket browser, opened at the folder this episode sits in. `highlight` is the
    /// file to scroll to and mark once it's there.
    case browse(providerID: String, folder: String?, highlight: String?)
}

/// How many marks this episode has, on the shoulder of the button that makes them.
/// Drawn outside the glyph rather than beside it, so the row of controls stays centred.
struct MarkCountBadge: View {
    let count: Int
    var offset = CGSize(width: 11, height: -7)

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.accentColor, in: Capsule())
                .offset(x: offset.width, y: offset.height)
                // Rolls rather than blinks — the point is that it went *up*.
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: count)
                .fixedSize()
        }
    }
}
