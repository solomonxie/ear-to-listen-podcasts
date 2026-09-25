import Foundation
import ImageIO
import UniformTypeIdentifiers

/// On-disk storage for pictures the listener picked themselves — speaker photos and
/// episode artwork — keyed by a generated filename (not the row id, so replacing an
/// image doesn't clash with anything still referencing the old one until the caller
/// re-points its `…FileName` column). Lives outside `AudioCache` since these are user
/// edits meant to persist, not a re-fetchable cache — they're what a `LibrarySnapshot`
/// backup bundles alongside `snapshot.json`.
struct ImageFileStore: Sendable {
    static let speakerPhotos = ImageFileStore(folderName: "SpeakerPhotos")
    static let artwork = ImageFileStore(folderName: "Artwork")

    let directory: URL

    init(folderName: String) {
        directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        return directory.appendingPathComponent(fileName)
    }

    /// Saves JPEG data under a fresh filename. Doesn't remove any previous image — the
    /// caller (already holding the old filename) does that once the new one's persisted.
    @discardableResult
    func save(_ data: Data) throws -> String {
        try Self.write(data, in: directory)
    }

    /// Saves a picked photo as a JPEG no larger than `maxDimension` pixels on its long
    /// edge — the only way images enter here, so no caller has to know the encoding.
    ///
    /// Shrunk by ImageIO straight from the file's bytes, and never through a full-size
    /// `UIImage`: today's phone photos are tens of megapixels, and decoding one whole —
    /// then drawing it again to shrink it — is several hundred megabytes of bitmap. That
    /// is enough for iOS to kill the app the moment a picture is picked, which is exactly
    /// what it did. The work also runs off the main actor, since it's the only part of
    /// picking a photo that takes any real time.
    func save(_ data: Data, maxDimension: CGFloat) async throws -> String {
        let directory = directory
        return try await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try Self.write(Self.downsampledJPEG(from: source, maxDimension: maxDimension), in: directory)
        }.value
    }

    /// The same, for a photo still sitting on disk — the picker's route in. Nothing ever
    /// holds the original: ImageIO reads only as much of the file as the smaller size
    /// needs.
    func save(contentsOf url: URL, maxDimension: CGFloat) async throws -> String {
        let directory = directory
        return try await Task.detached(priority: .userInitiated) {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try Self.write(Self.downsampledJPEG(from: source, maxDimension: maxDimension), in: directory)
        }.value
    }

    private static func downsampledJPEG(from source: CGImageSource, maxDimension: CGFloat) throws -> Data {
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Bakes in the EXIF orientation, so a photo taken sideways is stored the way
            // it was seen rather than rotated wherever it's shown.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ] as [CFString: Any] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return jpeg as Data
    }

    private static func write(_ jpeg: Data, in directory: URL) throws -> String {
        // The folder is made in `init`, but Remove All App Data takes it away under a
        // live instance — without this, every photo saved after a reset fails until the
        // app is relaunched.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(UUID().uuidString).jpg"
        try jpeg.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    func remove(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
