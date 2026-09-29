import Foundation

/// What order the episodes of one collection are in, and the number each of them carries.
///
/// **Filename order is the order.** `ep-9` before `ep-10`, because
/// `localizedStandardCompare` compares digit runs as numbers. `Track.trackNumber` is
/// what's shown, not what's sorted by.
///
/// **Filling in a missing number takes the filename's own, when the filenames agree on
/// one.** `ep-007.mp3` should become episode 7, not episode 3 because it happens to be
/// third in the folder. That's only safe when every file in the album offers a number and
/// no two offer the same one — one ambiguous name and the whole album falls back to
/// counting in filename order, which is at least always right about the *order*.
///
/// **Only a number someone typed is fixed.** One the app filled in is worked out again
/// on every pass, from the filenames alone — so a pass that once read a name wrong, or
/// files that arrived later and belong in the middle, don't leave the album out of order
/// for good. Hand edits (`metadataEditedAt`) are never touched.
enum EpisodeNumbers {
    /// The episodes of one collection, in the order to list and play them: by filename.
    /// Not by number — any edit pins a row's number (`metadataEditedAt`), so a number the
    /// app once misread stayed forever and put 014 right after 002.
    static func ordered(_ tracks: [Track]) -> [Track] {
        tracks.sorted(by: isBefore)
    }

    /// The number each episode that isn't fixed should carry, keyed by track id. By default
    /// only unnumbered episodes are open; the library pass also opens every number the app
    /// assigned itself, so it can be worked out afresh.
    ///
    /// Fixed numbers are never handed out twice, so an album where half the episodes were
    /// numbered by hand gets the rest placed after them rather than on top of them.
    static func assigned(_ tracks: [Track], isFixed: (Track) -> Bool = { $0.trackNumber != nil }) -> [String: Int] {
        // Ordered by filename alone: an open episode's old number is what's in question,
        // so it can't be allowed to decide its own place.
        let missing = ordered(tracks.filter { !isFixed($0) }.map { var open = $0; open.trackNumber = nil; return open })
        guard !missing.isEmpty else { return [:] }

        var taken = Set(tracks.filter(isFixed).compactMap(\.trackNumber))
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
    /// Plainly means one of three things, in this order: a sequence number the name starts
    /// with (`013_…`), a number right after a word that introduces one (`ep`, `episode`,
    /// `part`, `#`, `第`…), or a name whose digits all belong to a single run. Anything
    /// else — `2024-05-03 show.mp3` — is a name with a date in it, and guessing which run
    /// is the episode is how a library ends up numbered by year.
    ///
    /// The leading number wins over "Part 1": `013_Jesus Before Pilate, Part 1` is 13th in
    /// the folder, and the part is within a sermon series that started elsewhere. Reading
    /// the part first numbered that album against its own filenames.
    static func number(inFileName path: String) -> Int? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Short or zero-padded, then a separator, then words: a year (`2024 Episode 12`)
        // or a date (`2024-05-03`) isn't a place in the folder.
        if let leading = name.firstMatch(of: /^(0\d{3,4}|\d{1,3})[\s._\-]+(?=\D)/) {
            return Int(leading.1)
        }
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
