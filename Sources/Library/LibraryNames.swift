import Foundation
import GRDB

/// The album and speaker each episode belongs to, in memory.
///
/// Every list of episodes wants to say which collection and whose voice a row is — that's
/// what tells two files with the same embedded title apart — and reading those two rows
/// per row would be two queries per cell while the list scrolls. There are far fewer
/// albums and speakers than episodes, so they're held whole and refreshed when the
/// library changes.
@MainActor
final class LibraryNames: ObservableObject {
    static let shared = LibraryNames()

    @Published private(set) var albums: [String: Album] = [:]
    @Published private(set) var speakers: [String: Artist] = [:]

    private let store = LibraryStore(dbQueue: DatabaseManager.shared.dbQueue)

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: .libraryDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in LibraryNames.shared.refresh() }
        }
    }

    func album(_ id: String?) -> Album? { id.flatMap { albums[$0] } }
    func speaker(_ id: String?) -> Artist? { id.flatMap { speakers[$0] } }

    /// What a row says under an episode's title: which collection, and whose voice.
    func subtitle(for track: Track) -> String? {
        let parts = [album(track.albumID)?.name, speaker(track.artistID)?.name]
            .compactMap { $0?.nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func refresh() {
        albums = Dictionary(
            ((try? store.albums()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        speakers = Dictionary(
            ((try? store.artists()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
    }
}
