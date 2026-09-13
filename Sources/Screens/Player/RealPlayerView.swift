import SwiftUI

/// Minimal now-playing sheet for real, synced `Track`s — separate from the mock-data
/// `NowPlayingView` used by the rest of the app today. Exists so `PlaybackEngine`
/// (and the live transcription it drives) is actually reachable from the UI.
struct RealPlayerView: View {
    @ObservedObject var engine = PlaybackEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let track = engine.currentTrack {
                    Text(track.title).font(.title3.bold()).multilineTextAlignment(.center).padding(.horizontal)

                    Slider(
                        value: Binding(get: { engine.currentTime }, set: { engine.seek(to: $0) }),
                        in: 0...max(engine.duration, 1)
                    )
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

                    transcriptSection
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
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
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
