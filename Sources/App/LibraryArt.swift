import SwiftUI

/// Deterministic placeholder artwork for real library items (tracks, albums, speakers,
/// topics) — none of them carry actual cover art, so a stable color+icon derived from
/// their name stands in, rather than every card looking identical.
enum LibraryArt {
    private static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .brown, .red]
    private static let symbols = ["waveform", "mic.fill", "person.wave.2.fill", "quote.bubble.fill"]

    static func color(for seed: String) -> Color {
        colors[abs(seed.hashValue) % colors.count]
    }

    static func symbol(for seed: String) -> String {
        symbols[abs(seed.hashValue) % symbols.count]
    }
}
