import PhotosUI
import SwiftUI
import UIKit

/// A speaker's page, and their editor — the same thing. Photo, name and every detail
/// below are live here and commit when they lose focus; an Edit button opening a second
/// copy of the page was a screen transition and a Save to remember for changing one word
/// already on screen.
///
/// Details are ordinary form rows — label left, value right, tap the value and type —
/// matching `AlbumDetailView`. Three glyphs, three meanings, never mixed: a plain value
/// is typeable, `⌄` is a picker, `›` goes somewhere.
///
/// Most of what's worth knowing about a speaker isn't in an MP3 tag, so `⋯ → Build
/// profile with AI` fills these in from the episode titles and collections already here.
struct SpeakerDetailView: View {
    let speaker: Artist
    @State private var currentSpeaker: Artist
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var name = ""
    @State private var bio = ""
    @State private var knownFor = ""
    @State private var background = ""
    @State private var profile = ""
    @State private var link = ""
    @State private var language: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var suggestions = ProfileSuggestionState()
    @State private var isSuggesting = false
    @State private var suggestionError: String?
    /// Which unfolding picker is open — one at a time, across the whole form.
    @State private var openPicker: String?
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

                }
                .listRowSeparator(.hidden)
                .task(id: photoItem) { await handlePick() }
            }

            Section {
                StackedField("Bio", placeholder: "One line — what they're known for", text: $bio)
                    .focused($focusedField, equals: .bio)
                rejectNote("bio")
                StackedField("Known for", placeholder: "The themes they return to", text: $knownFor)
                    .focused($focusedField, equals: .knownFor)
                rejectNote("knownFor")
                // Here because it decides how this speaker's episodes get transcribed — a
                // transcript coming out as nonsense is almost always this being unset or
                // wrong.
                SpokenLanguagePicker(
                    title: "Language", inheritedLabel: "automatic", language: $language,
                    id: "language", open: $openPicker
                )
                StackedField(
                    "Background", placeholder: "Role, affiliation, what came before",
                    text: $background
                )
                .focused($focusedField, equals: .background)
                rejectNote("background")

                // Opened, not embedded: it's a claim from the model, and the only way to
                // know whether it's right is to look.
                if let url = link.nilIfEmpty.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        HStack {
                            Label(url.host ?? "Public page", systemImage: "safari")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.subheadline)
                    }
                }
                rejectNote("link")
            } header: {
                HStack {
                    Text("Details")
                    Spacer()
                    SuggestWithAiButton(isRunning: isSuggesting) { Task { await suggest() } }
                        .disabled(tracks.isEmpty && albums.isEmpty)
                }
            } footer: {
                if let suggestionError {
                    Text(suggestionError).foregroundStyle(.orange)
                }
            }

            // Its own section rather than a fourth row: it's paragraphs, and it's the part
            // of the page worth actually reading.
            Section("Profile") {
                TextField(
                    "Who they are and what they cover — or fill it in from ⋯ → Build profile with AI",
                    text: $profile, axis: .vertical
                )
                .lineLimit(3...)
                .focused($focusedField, equals: .profile)
                rejectNote("profile")
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
        // Leaving a field is the save, as everywhere else in the app.
        .onChange(of: focusedField) { previous, _ in
            guard previous != nil else { return }
            save()
        }
        .onChange(of: language) { _, _ in save() }
        .navigationTitle(currentSpeaker.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// Fills the fields from the speaker — but never over one being typed into.
    private func seedFields() {
        guard focusedField == nil else { return }
        name = currentSpeaker.name
        bio = currentSpeaker.bio ?? ""
        knownFor = currentSpeaker.knownFor ?? ""
        background = currentSpeaker.background ?? ""
        profile = currentSpeaker.profile ?? ""
        link = currentSpeaker.link ?? ""
        language = currentSpeaker.language
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? libraryStore.updateArtist(
            id: currentSpeaker.id,
            name: trimmed.nilIfEmpty ?? currentSpeaker.name,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            language: language,
            knownFor: .some(knownFor.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty),
            background: .some(background.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty),
            profile: .some(profile.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty),
            link: .some(link.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        )
        currentSpeaker = (try? libraryStore.artist(id: currentSpeaker.id)) ?? currentSpeaker
        // Home holds its own copy of these rows, so it needs telling — otherwise the new
        // name only appears on its shelves after some unrelated refresh.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    @ViewBuilder
    private func rejectNote(_ id: String) -> some View {
        if suggestions.wasSuggested(id) {
            SuggestedFieldNote { reject(id) }
        }
    }

    /// One tap: run it, write it into the fields, save. What came back is visible in the
    /// page itself and each field can be put back on its own — so there's nothing to
    /// confirm, and nothing is lost by trying it.
    private func suggest() async {
        isSuggesting = true
        suggestionError = nil
        defer { isSuggesting = false }
        do {
            let suggestion = try await SpeakerProfileSuggester()
                .analyze(speaker: currentSpeaker, albums: albums, tracks: tracks)
            guard !suggestion.isEmpty else {
                suggestionError = "Nothing to add — there wasn't enough here to go on."
                return
            }
            // A snapshot first: this writes several fields at once, and `reject` only
            // reaches back as far as this screen's memory of them.
            if let current = try? BackupService().currentArchive() {
                LocalBackups.writeBefore("speaker-profile", archive: current)
            }
            apply(suggestion.bio, id: "bio")
            apply(suggestion.knownFor, id: "knownFor")
            apply(suggestion.background, id: "background")
            apply(suggestion.profile, id: "profile")
            apply(suggestion.link, id: "link")
            save()
        } catch {
            suggestionError = error.localizedDescription
        }
    }

    /// Writes one suggested field, remembering what it replaced. A nil means the pass had
    /// nothing to say about that field — which is a real answer, not a blank to write.
    private func apply(_ text: String?, id: String) {
        guard let text else { return }
        switch id {
        case "bio": suggestions.record(id, previous: bio); bio = text
        case "knownFor": suggestions.record(id, previous: knownFor); knownFor = text
        case "background": suggestions.record(id, previous: background); background = text
        case "profile": suggestions.record(id, previous: profile); profile = text
        case "link": suggestions.record(id, previous: link); link = text
        default: return
        }
    }

    private func reject(_ id: String) {
        guard let previous = suggestions.reject(id) else { return }
        switch id {
        case "bio": bio = previous
        case "knownFor": knownFor = previous
        case "background": background = previous
        case "profile": profile = previous
        case "link": link = previous
        default: return
        }
        save()
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

private enum SpeakerField: Hashable {
    case name, bio, knownFor, background, profile
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
