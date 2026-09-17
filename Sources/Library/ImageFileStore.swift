import Foundation
import UIKit

/// On-disk storage for pictures the listener picked themselves — speaker photos and
/// episode artwork — keyed by a generated filename (not the row id, so replacing an
/// image doesn't clash with anything still referencing the old one until the caller
/// re-points its `…FileName` column). Lives outside `AudioCache` since these are user
/// edits meant to persist, not a re-fetchable cache — they're what a `LibrarySnapshot`
/// backup bundles alongside `snapshot.json`.
struct ImageFileStore {
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
        let fileName = "\(UUID().uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(fileName))
        return fileName
    }

    /// Saves a picked photo as a JPEG no larger than `maxDimension` on its long edge —
    /// the only way images enter here, so neither caller has to know the encoding.
    @discardableResult
    func save(_ image: UIImage, maxDimension: CGFloat) throws -> String {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let resized: UIImage
        if scale < 1 {
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        } else {
            resized = image
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try save(jpeg)
    }

    func remove(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }
}
