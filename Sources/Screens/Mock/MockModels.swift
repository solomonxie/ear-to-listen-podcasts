import SwiftUI

// Placeholder domain types for the podcast UI/UX pass. In-memory only —
// not backed by `Sources/DB`. Superseded once the real schema lands.

struct Speaker: Identifiable, Hashable {
    let id: String
    var name: String
    var bio: String
}

struct PodcastShow: Identifiable, Hashable {
    let id: String
    let title: String
    let speakerIDs: [String]
    let year: Int
    let topicIDs: [String]
    let summary: String
    let artColor: Color
    let symbol: String
}

struct TranscriptLine: Identifiable, Hashable {
    var id: Double { startSeconds }
    let startSeconds: Double
    let speaker: String
    let text: String
}

struct PodcastEpisode: Identifiable, Hashable {
    let id: String
    let showID: String
    let title: String
    let publishedYear: Int
    let durationSeconds: Int
    let summary: String
    /// Bundled demo clip name under Resources/DemoAudio (no extension), if any.
    let audioFileName: String?
    let transcript: [TranscriptLine]
    /// Manually credited speakers beyond the show's regular hosts (e.g. a one-off guest).
    var extraSpeakerIDs: [String] = []
}

struct Topic: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
}

struct PlaylistUI: Identifiable, Hashable {
    let id: String
    var name: String
    var episodeIDs: [String]
    var coverColors: [Color]
}

/// A curated, released collection with its own metadata — like a music album.
/// Distinct from a playlist, which freely mixes episodes from any album/show.
struct PodcastAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    var speakerIDs: [String]
    let description: String
    let releaseDate: Date
    let episodeIDs: [String]
    let artColor: Color
    let symbol: String
}

