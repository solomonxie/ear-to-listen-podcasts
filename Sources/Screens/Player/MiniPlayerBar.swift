import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var playback: PlaybackMockState
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let episode = playback.currentEpisode {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(MockLibraryStore.shared.show(episode.showID)?.artColor ?? .gray)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: MockLibraryStore.shared.show(episode.showID)?.symbol ?? "mic.fill")
                                .foregroundStyle(.white)
                                .font(.caption)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(MockLibraryStore.shared.show(episode.showID)?.title ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        playback.toggle()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    ProgressView(value: playback.duration > 0 ? playback.progress / playback.duration : 0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(height: 1.5)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
