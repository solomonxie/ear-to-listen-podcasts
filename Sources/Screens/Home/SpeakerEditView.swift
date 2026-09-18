import PhotosUI
import SwiftUI

/// Edit a speaker's name/bio/photo. Crediting on shows/albums comes from the synced
/// metadata itself (an episode's embedded artist tag), not a manual link, so isn't
/// editable here.
struct SpeakerEditView: View {
    let speaker: Artist
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var bio: String
    @State private var language: String?
    @State private var photoFileName: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var isSearchingPhoto = false
    @State private var photoSearchMessage: String?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
        _bio = State(initialValue: speaker.bio ?? "")
        _language = State(initialValue: speaker.language)
        _photoFileName = State(initialValue: speaker.photoFileName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // `previewFileName` is captured by value below rather than reading
                    // `photoFileName` inside the closure — `PhotosPicker`'s label closure is
                    // `@Sendable`, so it can't touch this main-actor-isolated view's state
                    // directly.
                    let previewFileName = photoFileName
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                SpeakerPhotoPreview(photoFileName: previewFileName)
                            }
                            // Both ways of getting a picture sit together: pick one from
                            // your library, or take one from this speaker's own episodes.
                            Button {
                                Task { await choosePhotoAutomatically() }
                            } label: {
                                if isSearchingPhoto {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Use episode artwork", systemImage: "wand.and.stars")
                                }
                            }
                            .font(.footnote)
                            .disabled(isSearchingPhoto)

                            if photoFileName != nil {
                                Button("Remove Photo", role: .destructive) { removePhoto() }
                                    .font(.footnote)
                            }
                            if let photoSearchMessage {
                                Text(photoSearchMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        Spacer()
                    }
                }
                .listRowSeparator(.hidden)

                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Picker("Language", selection: $language) {
                        Text("Not set").tag(String?.none)
                        ForEach(AppleSpeechTranscriber.supportedLocales, id: \.identifier) { locale in
                            Text(TranscriptPane.languageName(locale))
                                .tag(String?.some(locale.identifier(.bcp47)))
                        }
                    }
                } header: {
                    Text("Spoken language")
                } footer: {
                    Text("Used to transcribe this speaker's episodes. Recognizers have to be told which language to expect — they can't work it out, and the wrong one returns confident nonsense rather than failing.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: photoItem) { _, newItem in
                Task { await handlePick(newItem) }
            }
        }
    }

    private func choosePhotoAutomatically() async {
        isSearchingPhoto = true
        photoSearchMessage = nil
        defer { isSearchingPhoto = false }
        guard let data = await SpeakerPhotoFinder.find(for: speaker.id),
              let newFileName = try? await ImageFileStore.speakerPhotos.save(data, maxDimension: 400) else {
            photoSearchMessage = "No artwork found on this speaker's episodes."
            return
        }
        discardIfUncommitted(photoFileName)
        photoFileName = newFileName
    }

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item, let picked = try? await item.loadTransferable(type: PickedImageFile.self) else { return }
        defer { picked.discard() }
        guard let newFileName = try? await ImageFileStore.speakerPhotos.save(contentsOf: picked.url, maxDimension: 400) else { return }
        // Drop a photo picked earlier in this same session but never committed via Save.
        discardIfUncommitted(photoFileName)
        photoFileName = newFileName
    }

    private func removePhoto() {
        discardIfUncommitted(photoFileName)
        photoFileName = nil
    }

    private func cancel() {
        discardIfUncommitted(photoFileName)
        dismiss()
    }

    private func discardIfUncommitted(_ fileName: String?) {
        guard fileName != speaker.photoFileName else { return }
        ImageFileStore.speakerPhotos.remove(fileName)
    }

    private func save() {
        try? libraryStore.updateArtist(
            id: speaker.id, name: name, bio: bio.isEmpty ? nil : bio, language: language
        )
        if photoFileName != speaker.photoFileName {
            ImageFileStore.speakerPhotos.remove(speaker.photoFileName)
            try? libraryStore.updateArtistPhoto(id: speaker.id, photoFileName: photoFileName)
        }
        // Home holds its own copy of these rows, so it needs telling — otherwise the new
        // name/photo only appears on its shelves after some unrelated refresh.
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        dismiss()
    }
}

/// A standalone view (rather than a computed property) so `PhotosPicker`'s label closure
/// doesn't capture `SpeakerEditView`'s `self` across an actor boundary.
private struct SpeakerPhotoPreview: View {
    let photoFileName: String?

    var body: some View {
        SpeakerAvatar(photoFileName: photoFileName, size: 96)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.caption)
                    .padding(6)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
    }
}
