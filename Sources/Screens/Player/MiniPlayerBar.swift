import SwiftUI

struct MiniPlayerBar: View {
    @ObservedObject private var engine = PlaybackEngine.shared
    @Binding var showingNowPlaying: Bool
    @State private var artistName: String?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    var body: some View {
        if let track = engine.currentTrack {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LibraryArt.color(for: track.id).gradient)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Image(systemName: LibraryArt.symbol(for: track.id))
                                .foregroundStyle(.white)
                                .font(.caption)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let artistName {
                            Text(artistName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    ProgressView(value: engine.duration > 0 ? engine.currentTime / engine.duration : 0)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(height: 1.5)
                }
            }
            .buttonStyle(.plain)
            .task(id: track.id) {
                artistName = track.artistID.flatMap { try? libraryStore.artist(id: $0) }?.name
            }
        }
    }
}
