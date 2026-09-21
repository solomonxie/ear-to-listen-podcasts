import SwiftUI

/// The three playlists the app owns rather than the listener: **Listen Later**,
/// **Favorites** and **Downloaded**.
///
/// They're computed, not stored — the first two from a flag on the track, downloads from
/// what's actually in `AudioCache` — so there's no row to delete and nothing to keep in
/// sync. That's also why they're an enum rather than seeded `Playlist` records: "can't be
/// deleted" is a property of the type here, not a rule someone has to remember to enforce,
/// and no stray swipe or restored backup can take one away.
///
/// Both show even when empty. A listener who has favourited nothing yet still needs to be
/// told where favourites will appear — a shelf that materialises only once you've already
/// found the feature teaches nobody.
enum FixedPlaylist: String, CaseIterable, Identifiable {
    /// First, because it's the one you put things *into* — the other two fill themselves.
    case listenLater
    case favorites
    case downloaded

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .listenLater: return "Listen Later"
        case .favorites: return "Favorites"
        case .downloaded: return "Downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .listenLater: return "clock.fill"
        case .favorites: return "heart.fill"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .listenLater: return .indigo
        case .favorites: return .pink
        case .downloaded: return .teal
        }
    }

    /// Said in terms of what to do next, not just what's missing.
    var emptyMessage: LocalizedStringKey {
        switch self {
        case .listenLater: return "Nothing lined up yet. Hold an episode anywhere in the library and choose Listen Later."
        case .favorites: return "Nothing favourited yet. Tap the heart on an episode to keep it here."
        case .downloaded: return "Nothing downloaded yet. Anything you play is saved here automatically."
        }
    }
}
