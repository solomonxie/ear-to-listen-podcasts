import SwiftUI
import UIKit

struct SpeakerDetailView: View {
    let speaker: Artist
    @State private var currentSpeaker: Artist
    @State private var shows: [Show] = []
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var showingEdit = false

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _currentSpeaker = State(initialValue: speaker)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    SpeakerAvatar(photoFileName: currentSpeaker.photoFileName, size: 96)
                    if let bio = currentSpeaker.bio {
                        Text(bio).font(.callout).foregroundStyle(.secondary)
                    }
                    // Shown here because it's what decides how this speaker's episodes get
                    // transcribed — a transcript coming out as nonsense is almost always
                    // this being unset or wrong.
                    Label(
                        currentSpeaker.language
                            .map { TranscriptPane.languageName(Locale(identifier: $0)) }
                            ?? "Language not set — tap Edit to choose",
                        systemImage: "globe"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        ForEach(shows) { show in Text(show.name).font(.caption.weight(.semibold)) }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Albums") {
                if albums.isEmpty {
                    Text("No albums yet").foregroundStyle(.secondary)
                }
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(album: album) } label: {
                        AlbumRow(album: album)
                    }
                }
            }

            Section("Episodes") {
                ForEach(tracks) { track in
                    Button {
                        PlaybackEngine.shared.open(track: track, queue: tracks)
                    } label: {
                        TrackRow(track: track)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(currentSpeaker.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showingEdit, onDismiss: { Task { await load() } }) {
            SpeakerEditView(speaker: currentSpeaker)
        }
    }

    private func load() async {
        currentSpeaker = (try? libraryStore.artist(id: speaker.id)) ?? currentSpeaker
        shows = (try? libraryStore.shows(forArtist: speaker.id)) ?? []
        albums = (try? libraryStore.albums(forArtist: speaker.id)) ?? []
        tracks = (try? trackStore.tracks(forArtist: speaker.id)) ?? []
        await fillMissingPhoto()
    }

    /// A speaker with no picture gets one from their own episodes' artwork rather than
    /// staying a grey silhouette. Only ever when there's nothing there — a photo the
    /// listener chose is never replaced — and it's saved like any other edit, so it can be
    /// swapped or removed in the edit sheet afterwards.
    private func fillMissingPhoto() async {
        guard currentSpeaker.photoFileName == nil else { return }
        guard let data = await SpeakerPhotoFinder.find(for: currentSpeaker.id),
              let fileName = try? await ImageFileStore.speakerPhotos.save(data, maxDimension: 400) else { return }
        // Re-read first: the sheet may have set one while this was running.
        let latest = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        guard latest.photoFileName == nil else {
            ImageFileStore.speakerPhotos.remove(fileName)
            return
        }
        try? libraryStore.updateArtistPhoto(id: currentSpeaker.id, photoFileName: fileName)
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
    }
}

struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LibraryArt.color(for: album.id).gradient)
                .frame(width: 40, height: 40)
                .overlay { Image(systemName: "square.stack.fill").foregroundStyle(.white) }
            Text(album.name).font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}
