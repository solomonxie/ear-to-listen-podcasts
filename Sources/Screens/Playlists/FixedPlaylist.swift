import SwiftUI

/// The playlists the app owns rather than the listener: **Listen Later**, **Favorites**,
/// **Downloaded**, **Listened** and **YouTube**.
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
    /// It fills itself as episodes are finished, and is where done ones go.
    case listened
    /// Every YouTube video added as an episode.
    case youTube

    /// What Home shows — YouTube's left out where YouTube doesn't reach.
    static var shown: [FixedPlaylist] {
        AppStorefront.isChina ? allCases.filter { $0 != .youTube } : allCases
    }

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .listenLater: return "Listen Later"
        case .favorites: return "Favorites"
        case .downloaded: return "Downloaded"
        case .listened: return "Listened"
        case .youTube: return "YouTube"
        }
    }

    /// `name` as a plain string, for drawing on a cover.
    var title: String {
        switch self {
        case .listenLater: return String(localized: "Listen Later")
        case .favorites: return String(localized: "Favorites")
        case .downloaded: return String(localized: "Downloaded")
        case .listened: return String(localized: "Listened")
        case .youTube: return "YouTube"
        }
    }

    var symbol: String {
        switch self {
        case .listenLater: return "clock.fill"
        case .favorites: return "heart.fill"
        case .downloaded: return "arrow.down.circle.fill"
        case .listened: return "checkmark.circle.fill"
        case .youTube: return "play.rectangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .listenLater: return .indigo
        case .favorites: return .pink
        case .downloaded: return .teal
        case .listened: return .green
        case .youTube: return .red
        }
    }

    /// Said in terms of what to do next, not just what's missing.
    var emptyMessage: LocalizedStringKey {
        switch self {
        case .listenLater: return "Nothing lined up yet. Hold an episode anywhere in the library and choose Listen Later."
        case .favorites: return "Nothing favourited yet. Tap the heart on an episode to keep it here."
        case .downloaded: return "Nothing downloaded yet. Anything you play is saved here automatically."
        case .listened: return "Nothing finished yet. An episode lands here when it plays to the end, or when you mark it listened."
        case .youTube: return "No videos yet. Paste a YouTube link into search on Home to add one."
        }
    }
}
