import SwiftUI

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingUpNext = false
    @State private var showingAddToPlaylist = false
    @State private var artist: Artist?
    /// Whether the transcript is still following playback. A manual scroll turns it off —
    /// auto-scroll yanking the page back while someone is reading is the single most
    /// hostile thing this screen can do.
    @State private var isFollowingTranscript = true
    /// Whether the big transport has scrolled out of sight. The docked bar is a stand-in
    /// for it, so showing both at once is just clutter.
    @State private var isTransportOffscreen = false

    private static let scrollSpace = "player.scroll"
    @ObservedObject private var transcript = LiveTranscript.shared
    @State private var album: Album?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        NavigationStack {
            Group {
                if let track = engine.currentTrack {
                    // One scroll for the whole screen, and one page: details, then the
                    // transcript under them. A segmented control between the two was a
                    // tab bar for two things that are read together — you check who the
                    // speaker is *because* of a line you just read — and it cost a tap
                    // and a lost scroll position every time.
                    ScrollViewReader { proxy in
                        page(for: track, proxy: proxy)
                            // Any deliberate drag hands control to the reader.
                            // `simultaneous` so it observes the scroll rather than
                            // competing with it.
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 12).onChanged { _ in
                                    isFollowingTranscript = false
                                }
                            )
                            .overlay(alignment: .bottom) { followAgainPill(proxy) }
                    }
                    // Pinned: the page is now arbitrarily long, and Up Next shouldn't be
                    // a scroll away at the bottom of a 40-minute transcript.
                    .safeAreaInset(edge: .bottom) {
                        if isTransportOffscreen { bottomBar.transition(.move(edge: .bottom)) }
                    }
                    .animation(.easeInOut(duration: 0.2), value: isTransportOffscreen)
                    .task(id: track.id) {
                        artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
                        album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
                    }
                } else {
                    ContentUnavailableView("Nothing playing", systemImage: "mic.slash")
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Not in the docked bar: that bar now appears only once the transport has
                // scrolled away, and these two must be reachable wherever you are.
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingUpNext = true
                        } label: {
                            Label("Up Next (\(engine.queue.count, format: .number.grouping(.never)))",
                                  systemImage: "list.bullet")
                        }
                        Button {
                            showingAddToPlaylist = true
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
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

    /// Split out of `body` purely so the type-checker can cope — it timed out once the
    /// transcript pane grew a binding and the page grew an overlay.
    private func page(for track: Track, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                artwork(for: track)
                titles(for: track)
                Scrubber(currentTime: engine.currentTime, duration: engine.duration) { engine.seek(to: $0) }
                    .padding(.horizontal)
                transport
                    .background { transportVisibilityProbe }
                if let lastError = engine.lastError {
                    Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                }
                EpisodeDetailsPane(playingTrack: track)

                Divider().padding(.horizontal)

                TranscriptPane(
                    currentTime: engine.currentTime,
                    scrollProxy: proxy,
                    isFollowing: $isFollowingTranscript
                ) { engine.seek(to: $0) }
            }
            .padding(.vertical)
        }
        .coordinateSpace(name: Self.scrollSpace)
    }

    private func artwork(for track: Track) -> some View {
        ArtworkTile(track: track, cornerRadius: 16, symbolSize: 64)
            .frame(height: 220)
            .padding(.horizontal)
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

    private var transport: some View {
        HStack(spacing: 48) {
            Button { engine.skipToPrevious() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { engine.skipToNext() } label: { Image(systemName: "forward.fill").font(.title) }
        }
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
            Color.clear.onChange(of: bottomEdge, initial: true) { _, edge in
                if isTransportOffscreen {
                    if edge > 96 { isTransportOffscreen = false }
                } else if edge < 0 {
                    isTransportOffscreen = true
                }
            }
        }
    }

    /// Offers the transcript back rather than snatching it: auto-scroll only resumes when
    /// it's asked to, so a long read is never interrupted by the page moving itself.
    @ViewBuilder
    private func followAgainPill(_ proxy: ScrollViewProxy) -> some View {
        if !isFollowingTranscript, !transcript.lines.isEmpty,
           let start = transcript.currentLine(at: engine.currentTime)?.start {
            Button {
                isFollowingTranscript = true
                withAnimation { proxy.scrollTo(start, anchor: .center) }
            } label: {
                Label("Back to now playing", systemImage: "arrow.down.to.line")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
