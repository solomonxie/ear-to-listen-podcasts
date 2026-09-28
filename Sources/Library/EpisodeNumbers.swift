import Foundation

/// What order the episodes of one collection are in, and the number each of them carries.
///
/// **The number in the metadata wins, and every episode ends up with one.** A collection
/// is a series — episode 2 follows episode 1 — and the only field that says so is
/// `Track.trackNumber`. Files arrive without it: nothing in the app reads a track-number
/// tag, so until someone typed one in, an album listed itself by title, which puts
/// "Episode 10" before "Episode 9" and scatters a hundred identically-tagged files at
/// random.
///
/// **Filenames are the fallback, read the way a person reads them.** `ep-9` before
/// `ep-10`, because `localizedStandardCompare` compares digit runs as numbers — plain
/// `<` is what makes 10 sort before 9 in the first place.
///
/// **Filling in a missing number takes the filename's own, when the filenames agree on
/// one.** `ep-007.mp3` should become episode 7, not episode 3 because it happens to be
/// third in the folder. That's only safe when every file in the album offers a number and
/// no two offer the same one — one ambiguous name and the whole album falls back to
/// counting in filename order, which is at least always right about the *order*.
///
/// A number already in the metadata is never overwritten: someone typed it, or a previous
/// pass settled it, and re-deriving it every sync would undo hand corrections.
enum EpisodeNumbers {
    /// The episodes of one collection, in the order to list and play them: by number
    /// where there is one, then by filename.
    static func ordered(_ tracks: [Track]) -> [Track] {
        tracks.sorted { first, second in
            switch (first.trackNumber, second.trackNumber) {
            case let (first?, second?) where first != second:
                return first < second
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return isBefore(first, second)
            }
        }
    }

    /// The number to write for each episode that hasn't got one, keyed by track id.
    /// Empty when they all have one.
    ///
    /// Numbers already in use are never handed out twice, so an album where half the
    /// episodes were numbered by hand gets the rest placed after them rather than on top
    /// of them.
    static func assigned(_ tracks: [Track]) -> [String: Int] {
        let missing = ordered(tracks.filter { $0.trackNumber == nil })
        guard !missing.isEmpty else { return [:] }

        var taken = Set(tracks.compactMap(\.trackNumber))
        let fromNames = missing.map { number(inFileName: $0.filePath) }
        let usable = fromNames.compactMap { $0 }
        let namesAgree = usable.count == missing.count
            && Set(usable).count == usable.count
            && usable.allSatisfy { !taken.contains($0) }

        var next = (taken.max() ?? 0) + 1
        var assigned: [String: Int] = [:]
        for (index, track) in missing.enumerated() {
            let number: Int
            if namesAgree {
                number = fromNames[index]!
            } else {
                while taken.contains(next) { next += 1 }
                number = next
            }
            taken.insert(number)
            assigned[track.id] = number
        }
        return assigned
    }

    /// The episode number a filename states, or nil when it doesn't state one plainly.
    ///
    /// Plainly means one of two things: a number right after a word that introduces one
    /// (`ep`, `episode`, `part`, `#`, `第`…), or a name whose digits all belong to a
    /// single run. Anything else — `2024-05-03 show.mp3` — is a name with a date in it,
    /// and guessing which run is the episode is how a library ends up numbered by year.
    static func number(inFileName path: String) -> Int? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let marked = name.firstMatch(of: /(?i)(?:ep|episode|part|pt|no|track|第)[\s._\-#]*(\d{1,5})/) {
            return Int(marked.1)
        }
        let runs = name.matches(of: /\d{1,5}/)
        guard runs.count == 1, let only = runs.first else { return nil }
        return Int(only.0)
    }

    /// Filename order, the way the Files app shows it: digit runs compared as numbers,
    /// and the full path only as a tie-break so two folders' files never interleave.
    private static func isBefore(_ first: Track, _ second: Track) -> Bool {
        let left = (first.filePath as NSString).lastPathComponent
        let right = (second.filePath as NSString).lastPathComponent
        switch left.localizedStandardCompare(right) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return first.filePath < second.filePath
        }
    }
}
