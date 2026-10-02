import ImageIO
import SwiftUI
import UIKit

/// List-row pictures for the car, made off the main actor and kept: a list is rebuilt on
/// every library change, and the same few dozen covers come round each time.
enum CarArtwork {
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    /// The episode's own picture, then its collection's, then a drawn tile, the same
    /// order the rest of the app uses.
    static func image(for track: Track, album: Album?, size: CGSize) async -> UIImage {
        let file = track.artworkFileName?.nilIfEmpty ?? album?.artworkFileName?.nilIfEmpty
        let seed = track.artworkFileName?.nilIfEmpty != nil ? track.id : (album?.id ?? track.id)
        return await image(file: file, seed: seed, size: size)
    }

    static func image(for album: Album, size: CGSize) async -> UIImage {
        await image(file: album.artworkFileName?.nilIfEmpty, seed: album.id, size: size)
    }

    static func image(forSpeaker artist: Artist, size: CGSize) async -> UIImage {
        await image(
            file: artist.photoFileName?.nilIfEmpty, store: .speakerPhotos, seed: artist.id, size: size
        )
    }

    private static func image(
        file: String?, store: ImageFileStore = .artwork, seed: String, size: CGSize
    ) async -> UIImage {
        let key = "\(file ?? seed)|\(Int(size.width))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) {
            file.flatMap { thumbnail(at: store.url(for: $0), size: size) } ?? tile(seed: seed, size: size)
        }.value
        cache.setObject(image, forKey: key)
        return image
    }

    private static func thumbnail(at url: URL?, size: CGSize) -> UIImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 3,
        ] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }

    /// `LibraryArt`'s colour and symbol, drawn with UIKit rather than rendered from
    /// SwiftUI, which would have to happen on the main actor.
    private static func tile(seed: String, size: CGSize) -> UIImage {
        let color = UIColor(LibraryArt.color(for: seed))
        let symbol = UIImage(systemName: LibraryArt.symbol(for: seed))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            guard let symbol else { return }
            let side = size.width * 0.45
            let scale = side / max(symbol.size.width, symbol.size.height)
            let drawn = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: CGRect(
                x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
        }
    }
}
