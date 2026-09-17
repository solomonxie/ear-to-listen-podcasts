import AVFoundation
import Foundation
import GRDB

/// Finds a profile picture for a speaker out of what the listener already has.
///
/// Three sources, in descending order of "they meant this": artwork they chose for one of
/// this speaker's albums, artwork on one of their episodes, then whatever is embedded in
/// the audio file itself — which for a podcast is usually the show's cover.
///
/// Nothing is fetched from the internet and nothing is inferred from the speaker's name.
/// Putting a stranger's face on a real person is worse than the grey placeholder, and a
/// name is not enough to identify anybody.
enum SpeakerPhotoFinder {
    /// How many episodes to open over the network before giving up. Cached ones are free
    /// and aren't counted against this.
    private static let remoteReadLimit = 3

    static func find(for artistID: String, dbQueue: DatabaseQueue = DatabaseManager.shared.dbQueue) async -> Data? {
        let libraryStore = LibraryStore(dbQueue: dbQueue)
        let trackStore = TrackStore(dbQueue: dbQueue)

        // Anything they picked by hand outranks anything we dig up.
        for album in (try? libraryStore.albums(forArtist: artistID)) ?? [] {
            if let data = chosenImage(album.artworkFileName) { return data }
        }
        let tracks = (try? trackStore.tracks(forArtist: artistID)) ?? []
        for track in tracks {
            if let data = chosenImage(track.artworkFileName) { return data }
        }

        // Already-downloaded episodes first: reading a local file beats range-requesting
        // a remote one, and a listener's downloads are the episodes they care about.
        var remote: [Track] = []
        for track in tracks {
            guard let cached = await AudioCache.shared.cachedURL(
                providerID: track.providerID, filePath: track.filePath
            ) else {
                remote.append(track)
                continue
            }
            if let data = await embeddedArtwork(at: cached) { return data }
        }
        for track in remote.prefix(remoteReadLimit) {
            guard let url = await streamURL(for: track, dbQueue: dbQueue) else { continue }
            if let data = await embeddedArtwork(at: url) { return data }
        }
        return nil
    }

    private static func chosenImage(_ fileName: String?) -> Data? {
        guard let url = ImageFileStore.artwork.url(for: fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The cover art tagged into the file. `AVURLAsset` range-requests only what it needs,
    /// so this doesn't pull the whole episode down.
    private static func embeddedArtwork(at url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    private static func streamURL(for track: Track, dbQueue: DatabaseQueue) async -> URL? {
        guard let record = try? ProviderStore(dbQueue: dbQueue).all().first(where: { $0.id == track.providerID }),
              let provider = try? ProviderManager.shared.provider(for: record) else { return nil }
        return try? await provider.streamURL(forFileID: track.filePath)
    }
}
