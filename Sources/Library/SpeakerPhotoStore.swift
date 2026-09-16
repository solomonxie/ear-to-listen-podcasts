import Foundation

/// On-disk storage for speaker profile photos, keyed by a generated filename (not the
/// speaker id, so replacing a photo doesn't clash with anything still referencing the old
/// one until the caller re-points `Artist.photoFileName`). Lives outside `AudioCache` since
/// these are user edits meant to persist, not a re-fetchable cache — they're what a
/// `LibrarySnapshot` backup bundles alongside `snapshot.json`.
enum SpeakerPhotoStore {
    static let directory: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakerPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return directory.appendingPathComponent(fileName)
    }

    /// Saves JPEG data under a fresh filename. Doesn't remove any previous photo — the
    /// caller (already holding the old filename) does that once the new one's persisted.
    @discardableResult
    static func save(_ data: Data) throws -> String {
        let fileName = "\(UUID().uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    static func remove(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
