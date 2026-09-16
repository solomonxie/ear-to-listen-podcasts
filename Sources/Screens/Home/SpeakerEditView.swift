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
    @State private var photoFileName: String?
    @State private var photoItem: PhotosPickerItem?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
        _bio = State(initialValue: speaker.bio ?? "")
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
                            if photoFileName != nil {
                                Button("Remove Photo", role: .destructive) { removePhoto() }
                                    .font(.footnote)
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
            }
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

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let resized = image.resized(maxDimension: 400)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85), let newFileName = try? SpeakerPhotoStore.save(jpeg) else { return }
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
        SpeakerPhotoStore.remove(fileName)
    }

    private func save() {
        try? libraryStore.updateArtist(id: speaker.id, name: name, bio: bio.isEmpty ? nil : bio)
        if photoFileName != speaker.photoFileName {
            SpeakerPhotoStore.remove(speaker.photoFileName)
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

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
