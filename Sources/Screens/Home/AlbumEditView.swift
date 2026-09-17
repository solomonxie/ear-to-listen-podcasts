import PhotosUI
import SwiftUI

/// Edit an album's own metadata — name, speaker, notes, artwork. The speaker is written
/// through to every episode in the album (`reassignAlbumArtist`), since a wrong speaker
/// here is wrong on all of them.
struct AlbumEditView: View {
    let album: Album
    let initialArtistName: String?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var artistName: String
    @State private var notes: String
    @State private var artworkFileName: String?
    @State private var artworkImage: UIImage?
    @State private var artworkItem: PhotosPickerItem?

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(album: Album, artistName: String?) {
        self.album = album
        self.initialArtistName = artistName
        _name = State(initialValue: album.name)
        _artistName = State(initialValue: artistName ?? "")
        _notes = State(initialValue: album.notes ?? "")
        _artworkFileName = State(initialValue: album.artworkFileName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    let preview = artworkImage
                    let seed = album.id
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            PhotosPicker(selection: $artworkItem, matching: .images) {
                                AlbumArtworkPreview(image: preview, seed: seed)
                            }
                            if artworkFileName != nil {
                                Button("Remove Artwork", role: .destructive) { removeArtwork() }
                                    .font(.footnote)
                            }
                        }
                        Spacer()
                    }
                }
                .listRowSeparator(.hidden)

                Section("Album") {
                    TextField("Name", text: $name, axis: .vertical).lineLimit(1...3)
                    TextField("Speaker", text: $artistName)
                }

                Section {
                    TextField("What this collection is", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Changing the speaker re-points every episode in this album, not just the album itself.")
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: artworkItem) { _, newItem in Task { await handlePick(newItem) } }
            .task(id: artworkFileName) { loadArtwork() }
        }
    }

    private func loadArtwork() {
        guard let url = ImageFileStore.artwork.url(for: artworkFileName), let data = try? Data(contentsOf: url) else {
            artworkImage = nil
            return
        }
        artworkImage = UIImage(data: data)
    }

    private func handlePick(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
              let newFileName = try? ImageFileStore.artwork.save(image, maxDimension: 800) else { return }
        discardIfUncommitted(artworkFileName)
        artworkFileName = newFileName
    }

    private func removeArtwork() {
        discardIfUncommitted(artworkFileName)
        artworkFileName = nil
    }

    private func cancel() {
        discardIfUncommitted(artworkFileName)
        dismiss()
    }

    private func discardIfUncommitted(_ fileName: String?) {
        guard fileName != album.artworkFileName else { return }
        ImageFileStore.artwork.remove(fileName)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try? libraryStore.updateAlbum(
            id: album.id,
            name: trimmedName.nilIfEmpty ?? album.name,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            artworkFileName: artworkFileName
        )
        let trimmedArtist = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArtist.isEmpty, trimmedArtist != initialArtistName {
            _ = try? libraryStore.reassignAlbumArtist(albumID: album.id, artistName: trimmedArtist)
        }
        if artworkFileName != album.artworkFileName {
            ImageFileStore.artwork.remove(album.artworkFileName)
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        dismiss()
    }
}

/// Stateless, so `PhotosPicker`'s `@Sendable` label closure doesn't capture the view.
private struct AlbumArtworkPreview: View {
    let image: UIImage?
    let seed: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(LibraryArt.color(for: seed).gradient)
                    .overlay { Image(systemName: "square.stack.fill").font(.system(size: 36)).foregroundStyle(.white) }
            }
        }
        .frame(width: 140, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.fill")
                .font(.caption)
                .padding(6)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}
