import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var playback: PlaybackEngine

    var body: some View {
        NavigationStack {
            Group {
                if playback.queue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "list.bullet")
                } else {
                    List(playback.queue) { track in
                        Button {
                            playback.play(track: track, queue: playback.queue)
                        } label: {
                            HStack {
                                if track.id == playback.currentTrack?.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                }
                                Text(track.title)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue")
        }
    }
}
