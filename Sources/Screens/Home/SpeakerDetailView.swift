import PhotosUI
import SwiftUI
import UIKit

/// A speaker's page, and their editor — the same thing. Photo, name, bio and the language
/// they speak are all live here and commit when they lose focus; an Edit button opening a
/// second copy of the page was a screen transition and a Save to remember for changing
/// one word already on screen.
struct SpeakerDetailView: View {
    let speaker: Artist
    @State private var currentSpeaker: Artist
    @State private var shows: [Show] = []
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var name = ""
    @State private var bio = ""
    @State private var language: String?
    @State private var photoItem: PhotosPickerItem?
    @FocusState private var focusedField: SpeakerField?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let trackStore = TrackStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _currentSpeaker = State(initialValue: speaker)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // The picture is the control, as it is on an album and an episode: a
                    // speaker page is mostly what a file's metadata claimed, and the parts
                    // that are wrong are the ones being looked at.
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            SpeakerAvatar(photoFileName: currentSpeaker.photoFileName, size: 96)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if currentSpeaker.photoFileName != nil {
                                Button("Remove Photo", systemImage: "trash", role: .destructive) { removePhoto() }
                            }
                        }
                        Spacer()
                    }

                    TextField("Name", text: $name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)

                    VStack(alignment: .leading, spacing: 10) {
                        SpeakerFieldRow(label: "Bio") {
                            TextField("What they're known for", text: $bio, axis: .vertical)
                                .lineLimit(1...6)
                                .focused($focusedField, equals: .bio)
                        }
                        // Here because it decides how this speaker's episodes get
                        // transcribed — a transcript coming out as nonsense is almost
                        // always this being unset or wrong.
                        SpeakerFieldRow(label: "Language") {
                            SpokenLanguagePicker(title: "", inheritedLabel: "automatic", language: $language)
                                .labelsHidden()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .font(.footnote)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    HStack {
                        ForEach(shows) { show in Text(show.name).font(.caption.weight(.semibold)) }
                    }
                }
                .listRowSeparator(.hidden)
                .task(id: photoItem) { await handlePick() }
                .onChange(of: focusedField) { previous, _ in
                    guard previous != nil else { return }
                    save()
                }
                .onChange(of: language) { _, _ in save() }
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
        .task { await load() }
    }

    /// Fills the fields from the speaker — but never over one being typed into.
    private func seedFields() {
        guard focusedField == nil else { return }
        name = currentSpeaker.name
        bio = currentSpeaker.bio ?? ""
        language = currentSpeaker.language
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? libraryStore.updateArtist(
            id: currentSpeaker.id,
            name: trimmed.nilIfEmpty ?? currentSpeaker.name,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            language: language
        )
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        // Home holds its own copy of these rows, so it needs telling — otherwise the new
        // name only appears on its shelves after some unrelated refresh.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func handlePick() async {
        guard let photoItem, let picked = try? await photoItem.loadTransferable(type: PickedImageFile.self) else { return }
        defer { picked.discard() }
        guard let fileName = try? await ImageFileStore.speakerPhotos.save(contentsOf: picked.url, maxDimension: 400) else { return }
        let previous = currentSpeaker.photoFileName
        try? libraryStore.updateArtistPhoto(id: currentSpeaker.id, photoFileName: fileName)
        ImageFileStore.speakerPhotos.remove(previous)
        self.photoItem = nil
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func removePhoto() {
        let previous = currentSpeaker.photoFileName
        try? libraryStore.updateArtistPhoto(id: currentSpeaker.id, photoFileName: nil)
        ImageFileStore.speakerPhotos.remove(previous)
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    private func load() async {
        currentSpeaker = (try? libraryStore.artist(id: speaker.id)) ?? currentSpeaker
        shows = (try? libraryStore.shows(forArtist: speaker.id)) ?? []
        albums = (try? libraryStore.albums(forArtist: speaker.id)) ?? []
        tracks = (try? trackStore.tracks(forArtist: speaker.id)) ?? []
        seedFields()
        await fillMissingPhoto()
    }

    /// A speaker with no picture gets one from their own episodes' artwork rather than
    /// staying a grey silhouette. Only ever when there's nothing there — a photo the
    /// listener chose is never replaced — and it's saved like any other edit, so tapping
    /// the avatar can swap it afterwards.
    private func fillMissingPhoto() async {
        guard currentSpeaker.photoFileName == nil else { return }
        guard let data = await SpeakerPhotoFinder.find(for: currentSpeaker.id),
              let fileName = try? await ImageFileStore.speakerPhotos.save(data, maxDimension: 400) else { return }
        // Re-read first: a photo may have been picked while this was running.
        let latest = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        guard latest.photoFileName == nil else {
            ImageFileStore.speakerPhotos.remove(fileName)
            return
        }
        try? libraryStore.updateArtistPhoto(id: currentSpeaker.id, photoFileName: fileName)
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
    }
}

/// One editable row on the speaker header, matching the album page's.
private struct SpeakerFieldRow<Content: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum SpeakerField: Hashable {
    case name, bio
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
