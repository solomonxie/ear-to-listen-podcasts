import SwiftUI

/// Edit a speaker's metadata and manually link/unlink albums and episodes —
/// beyond the automatic crediting derived from show hosts.
struct SpeakerEditView: View {
    let speaker: Speaker
    @EnvironmentObject private var library: MockLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var bio: String

    init(speaker: Speaker) {
        self.speaker = speaker
        _name = State(initialValue: speaker.name)
        _bio = State(initialValue: speaker.bio)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Bio", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Albums") {
                    ForEach(library.albums) { album in
                        Toggle(album.title, isOn: albumBinding(album))
                    }
                }

                Section {
                    ForEach(library.episodes) { episode in
                        let viaShow = library.isSpeakerCreditedViaShow(speaker.id, episodeID: episode.id)
                        Toggle(episode.title, isOn: episodeBinding(episode))
                            .disabled(viaShow)
                            .foregroundStyle(viaShow ? .secondary : .primary)
                    }
                } header: {
                    Text("Episodes")
                } footer: {
                    Text("Episodes already credited via a show's hosts can't be unlinked here.")
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
                        library.updateSpeaker(id: speaker.id, name: name, bio: bio)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func albumBinding(_ album: PodcastAlbum) -> Binding<Bool> {
        Binding(
            get: { album.speakerIDs.contains(speaker.id) },
            set: { library.setSpeaker(speaker.id, linkedToAlbum: album.id, linked: $0) }
        )
    }

    private func episodeBinding(_ episode: PodcastEpisode) -> Binding<Bool> {
        Binding(
            get: {
                episode.extraSpeakerIDs.contains(speaker.id)
                    || library.isSpeakerCreditedViaShow(speaker.id, episodeID: episode.id)
            },
            set: { library.setSpeaker(speaker.id, linkedToEpisode: episode.id, linked: $0) }
        )
    }
}
