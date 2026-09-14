import SwiftUI

/// Edit a speaker's name/bio. Crediting on shows/albums comes from the synced metadata
/// itself (an episode's embedded artist tag), not a manual link, so isn't editable here.
struct SpeakerEditView: View {
    let speaker: Artist
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var bio: String

    private let libraryStore = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    init(speaker: Artist) {
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
        _bio = State(initialValue: speaker.bio ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
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
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        try? libraryStore.updateArtist(id: speaker.id, name: name, bio: bio.isEmpty ? nil : bio)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
