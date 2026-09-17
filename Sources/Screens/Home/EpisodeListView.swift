import SwiftUI

/// Shared list used for year/topic browsing from Home.
struct EpisodeListView: View {
    let title: String
    let tracks: [Track]

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("No episodes yet", systemImage: "mic.slash")
            } else {
                List(tracks) { track in
                    Button {
                        PlaybackEngine.shared.open(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
