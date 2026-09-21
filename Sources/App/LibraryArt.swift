import SwiftUI
import UIKit

/// Deterministic placeholder artwork for real library items (tracks, albums, speakers,
/// topics) — none of them carry actual cover art, so a stable color+icon derived from
/// their name stands in, rather than every card looking identical.
enum LibraryArt {
    private static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .brown, .red]
    private static let symbols = ["waveform", "mic.fill", "person.wave.2.fill", "quote.bubble.fill"]

    static func color(for seed: String) -> Color {
        colors[stableHash(seed) % colors.count]
    }

    static func symbol(for seed: String) -> String {
        symbols[stableHash(seed) % symbols.count]
    }

    /// FNV-1a over the seed's bytes, because **`String.hashValue` is seeded per process**:
    /// the same episode drew a different colour on every launch, and the tile a listener
    /// learns to recognise is worth less than nothing if it isn't the same tomorrow. Any
    /// stable function of the bytes does; this one is four lines and needs no import.
    private static func stableHash(_ seed: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(Int.max))
    }

    /// The same tile as a bitmap, for the places outside SwiftUI that can only take a
    /// picture — Control Center and the lock screen, which otherwise show a grey square
    /// for every episode whose artwork nobody set.
    static func image(for seed: String, size: CGFloat = 512) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: bounds.size).image { context in
            UIColor(color(for: seed)).setFill()
            context.fill(bounds)
            let glyph = UIImage(
                systemName: symbol(for: seed),
                withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.34, weight: .semibold)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal)
            guard let glyph else { return }
            glyph.draw(in: CGRect(
                x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height / 2,
                width: glyph.size.width, height: glyph.size.height
            ))
        }
    }
}
