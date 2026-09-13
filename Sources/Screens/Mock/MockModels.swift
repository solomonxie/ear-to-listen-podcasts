import SwiftUI

// Placeholder domain types for the podcast UI/UX pass. In-memory only —
// not backed by `Sources/DB`. Superseded once the real schema lands.

struct Speaker: Identifiable, Hashable {
    let id: String
    let name: String
    let bio: String
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

indirect enum RemoteEntry: Identifiable, Hashable {
    case folder(id: String, name: String, children: [RemoteEntry])
    case file(id: String, name: String, sizeBytes: Int, modified: String)

    var id: String {
        switch self {
        case .folder(let id, _, _): return id
        case .file(let id, _, _, _): return id
        }
    }

    var name: String {
        switch self {
        case .folder(_, let name, _): return name
        case .file(_, let name, _, _): return name
        }
    }
}
