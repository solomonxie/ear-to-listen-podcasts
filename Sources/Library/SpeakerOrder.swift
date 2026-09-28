import Foundation

/// What order the speakers on Home are in: whoever you listened to last, first.
///
/// Alphabetical is an order about the names, not about the library — the speaker you
/// spent last night with sat wherever the alphabet put them, and the shelf looked the
/// same every day no matter what was played. Last activity makes the shelf a short list
/// of who you're actually listening to, with everyone else still behind it.
///
/// Playing is the only thing that counts as activity. A sync or a metadata pass touches
/// every episode it imports, so counting those would reshuffle the shelf around whatever
/// happened to land last, which is not something anyone did.
enum SpeakerOrder {
    static func byLastActivity(_ speakers: [Artist], tracks: [Track]) -> [Artist] {
        var lastPlayed: [String: Date] = [:]
        for track in tracks {
            guard let speakerID = track.artistID, let playedAt = track.lastPlayedAt else { continue }
            if let known = lastPlayed[speakerID], known >= playedAt { continue }
            lastPlayed[speakerID] = playedAt
        }
        return speakers.sorted { first, second in
            switch (lastPlayed[first.id], lastPlayed[second.id]) {
            case let (first?, second?) where first != second:
                return first > second
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                // Never listened to, so there is nothing to rank them by but their names.
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        }
    }
}
