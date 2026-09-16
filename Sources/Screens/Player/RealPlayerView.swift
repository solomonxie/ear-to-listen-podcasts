import SwiftUI

/// The app's one now-playing screen, over real synced `Track`s via `PlaybackEngine`.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .details
    @State private var showingUpNext = false
    @State private var showingAddToPlaylist = false
    @State private var artist: Artist?
    @State private var album: Album?
    @State private var showSummary: String?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    private enum Tab: String, CaseIterable {
        case details = "Details"
        case transcript = "Transcript"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let track = engine.currentTrack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LibraryArt.color(for: track.id).gradient)
                        .frame(height: 220)
                        .overlay { Image(systemName: LibraryArt.symbol(for: track.id)).font(.system(size: 64)).foregroundStyle(.white) }
                        .padding(.horizontal)

                    VStack(spacing: 4) {
                        Text(track.title).font(.title3.bold()).multilineTextAlignment(.center)
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

                    Scrubber(currentTime: engine.currentTime, duration: engine.duration) { engine.seek(to: $0) }
                        .padding(.horizontal)

                    HStack(spacing: 48) {
                        Button { engine.skipToPrevious() } label: { Image(systemName: "backward.fill").font(.title) }
                        Button { engine.togglePlayPause() } label: {
                            Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        Button { engine.skipToNext() } label: { Image(systemName: "forward.fill").font(.title) }
                    }

                    if let lastError = engine.lastError {
                        Text(lastError).font(.footnote).foregroundStyle(.orange).padding(.horizontal)
                    }

                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    switch tab {
                    case .details:
                        ScrollView {
                            Text(showSummary ?? "No details for this episode.")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    case .transcript:
                        TranscriptSection(engine: engine)
                    }

                    HStack {
                        Button {
                            showingUpNext = true
                        } label: {
                            Label("Up Next (\(engine.queue.count, format: .number.grouping(.never)))", systemImage: "list.bullet")
                        }
                        Spacer()
                        Button {
                            showingAddToPlaylist = true
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                    .task(id: track.id) {
                        artist = track.artistID.flatMap { try? libraryStore.artist(id: $0) } ?? nil
                        album = track.albumID.flatMap { try? libraryStore.album(id: $0) } ?? nil
                        showSummary = track.showID.flatMap { try? libraryStore.show(id: $0) }?.summary
                    }
                } else {
                    Spacer()
                    ContentUnavailableView("Nothing playing", systemImage: "mic.slash")
                    Spacer()
                }
            }
            .padding(.top)
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
}

/// Drives itself from a locally-held drag position while the user's finger is down, so
/// `PlaybackEngine`'s periodic `currentTime` publishing (every 0.5s) can't yank the thumb
/// back mid-drag. A zero-distance drag gesture also means tapping anywhere on the track
/// jumps straight there, not just dragging the thumb.
private struct Scrubber: View {
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

private struct TranscriptSection: View {
    @ObservedObject var engine: PlaybackEngine

    var body: some View {
        if engine.isTranscribing {
            ProgressView("Transcribing…")
        } else if engine.transcript.isEmpty {
            ContentUnavailableView("No transcript for this episode", systemImage: "text.bubble")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(engine.transcript.enumerated()), id: \.offset) { _, segment in
                            let isCurrent = segment.start == engine.currentTranscriptSegment?.start
                            Text(segment.text)
                                .font(isCurrent ? .body.weight(.semibold) : .body)
                                .foregroundStyle(isCurrent ? .primary : .secondary)
                                .id(segment.start)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: engine.currentTranscriptSegment?.start) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
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
                        Text(track.title).lineLimit(1)
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
