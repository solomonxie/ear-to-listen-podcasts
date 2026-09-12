import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)

                if let track = playback.currentTrack {
                    Text(track.title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("Nothing playing")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }

                if let error = playback.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...max(playback.duration, 1)
                )
                .padding(.horizontal)
                .disabled(playback.currentTrack == nil)

                HStack(spacing: 48) {
                    Button { playback.skipToPrevious() } label: {
                        Image(systemName: "backward.fill").font(.title)
                    }
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    Button { playback.skipToNext() } label: {
                        Image(systemName: "forward.fill").font(.title)
                    }
                }
                .disabled(playback.currentTrack == nil)
                Spacer()
            }
            .navigationTitle("Now Playing")
        }
    }
}
