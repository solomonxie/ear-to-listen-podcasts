import SwiftUI

enum RemovalSubject {
    case episode(Track)
    case album(Album)
    case speaker(Artist)

    var noun: String {
        switch self {
        case .episode: return "episode"
        case .album: return "album"
        case .speaker: return "speaker"
        }
    }
}

enum RemovalChoice: Identifiable {
    case neglect, delete
    var id: Self { self }
}

/// Neglect hides and keeps; delete removes the entry and the file in its source.
private struct RemovalDialogs: ViewModifier {
    let subject: RemovalSubject
    @Binding var choice: RemovalChoice?
    let onDone: () -> Void
    @State private var failures: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                title, isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }),
                titleVisibility: .visible, presenting: choice
            ) { choice in
                switch choice {
                case .neglect: Button("Neglect") { neglect() }
                case .delete: Button("Delete Entry and Source File", role: .destructive) { delete() }
                }
            } message: { choice in
                Text(message(choice))
            }
            .alert("Couldn't delete everything", isPresented: Binding(get: { failures != nil }, set: { if !$0 { failures = nil } })) {
                Button("OK") {}
            } message: {
                Text(failures ?? "")
            }
    }

    private var title: String {
        choice == .delete ? "Delete this \(subject.noun)?" : "Neglect this \(subject.noun)?"
    }

    private func message(_ choice: RemovalChoice) -> String {
        switch choice {
        case .neglect:
            return "It disappears from your library and sync skips it. Nothing is deleted — bring it back from Settings → Flagged → Neglected."
        case .delete:
            return "The entry, its marks and notes, and the audio file in your storage are deleted. This can't be undone."
        }
    }

    private func stores() -> (TrackStore, LibraryStore) {
        let queue = DatabaseManager.shared.dbQueue
        return (TrackStore(dbQueue: queue), LibraryStore(dbQueue: queue))
    }

    private func neglect() {
        let (tracks, library) = stores()
        switch subject {
        case .episode(let track): try? tracks.setNeglected(ids: [track.id], neglected: true)
        case .album(let album): try? library.setAlbumNeglected(id: album.id, neglected: true)
        case .speaker(let speaker): try? library.setArtistNeglected(id: speaker.id, neglected: true)
        }
        record("Neglect")
        finish()
    }

    private func delete() {
        let removal = EpisodeRemoval()
        let library = stores().1
        Task {
            let result: EpisodeRemoval.Result
            switch subject {
            case .episode(let track): result = await removal.delete(trackIDs: [track.id])
            case .album(let album): result = await removal.deleteAlbum(id: album.id, libraryStore: library)
            case .speaker(let speaker): result = await removal.deleteArtist(id: speaker.id, libraryStore: library)
            }
            if result.failures.isEmpty {
                record("Delete")
                finish()
            } else {
                failures = result.failures.prefix(5).joined(separator: "\n")
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
        }
    }

    private func record(_ action: String) {
        let name: String
        switch subject {
        case .episode(let track): name = track.title
        case .album(let album): name = album.name
        case .speaker(let speaker): name = speaker.name
        }
        FixHistoryStore(dbQueue: DatabaseManager.shared.dbQueue)
            .record(action: "\(action) \(subject.noun)", count: 1, detail: name)
    }

    private func finish() {
        if case .episode(let track) = subject, PlaybackEngine.shared.currentTrack?.id == track.id {
            PlaybackEngine.shared.unload()
        }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        onDone()
    }
}

extension View {
    func removalDialogs(
        _ subject: RemovalSubject, choice: Binding<RemovalChoice?>, onDone: @escaping () -> Void
    ) -> some View {
        modifier(RemovalDialogs(subject: subject, choice: choice, onDone: onDone))
    }
}
