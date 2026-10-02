import Foundation

/// What order the episodes of one collection are in.
///
/// **Filename order is the order.** `ep-9` before `ep-10`, because
/// `localizedStandardCompare` compares digit runs as numbers.
enum EpisodeOrder {
    /// The episodes of one collection, in the order to list and play them.
    static func ordered(_ tracks: [Track]) -> [Track] {
        tracks.sorted(by: isBefore)
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
