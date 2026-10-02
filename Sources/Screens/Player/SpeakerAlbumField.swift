import SwiftUI

/// A YouTube episode's album: one of its speaker's, picked from the menu, or a new name
/// typed in. Left blank it's the speaker's default — the placeholder says which.
struct SpeakerAlbumField: View {
    let speaker: String
    @Binding var album: String
    @State private var albums: [Album] = []

    private var filedSpeaker: String { YouTubeEpisodes.filing(speaker: speaker, album: nil).speaker }

    var body: some View {
        HStack {
            TextField(YouTubeEpisodes.defaultAlbumName(for: filedSpeaker), text: $album)
            Menu {
                ForEach(albums) { existing in
                    Button(existing.name) { album = existing.name }
                }
                Button("Default: \(YouTubeEpisodes.defaultAlbumName(for: filedSpeaker))") { album = "" }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .accessibilityLabel("\(filedSpeaker)'s albums")
        }
        .task(id: filedSpeaker) {
            albums = (try? LibraryStore(dbQueue: DatabaseManager.shared.dbQueue).albums(forArtistNamed: filedSpeaker)) ?? []
        }
    }
}
