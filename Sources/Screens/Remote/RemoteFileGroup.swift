import Foundation

/// One episode plus the sidecar files that belong to it, matched on a shared basename —
/// `ep-01.mp3` owns `ep-01.vtt`, `ep-01.lrc`, `ep-01.zh-CN.vtt` and `ep-01.jpg`.
///
/// Sidecars live flat beside the audio rather than in a folder per episode: that's what
/// every other media tool reads, and it keeps the audio object itself untouched (see
/// `TranscriptSidecar`). The cost is that a 37-episode folder lists ~150 files, which is
/// what this grouping exists to fold back up.
struct RemoteFileGroup: Identifiable {
    /// The episode — or, for a file that belongs to nothing, itself.
    var file: CloudFile
    var sidecars: [CloudFile] = []

    var id: String { file.id }

    var hasTranscript: Bool {
        sidecars.contains { FileKind(path: $0.path) == .transcript }
    }

    /// Folds a flat listing into one row per episode. Anything that isn't audio and can't
    /// be matched to an episode here — a loose note, a bucket-level cover, this app's own
    /// backup — stays a row of its own rather than being hidden.
    static func group(_ files: [CloudFile]) -> [RemoteFileGroup] {
        var groups: [RemoteFileGroup] = []
        var indexByStem: [String: Int] = [:]
        var orphans: [CloudFile] = []

        for file in files where FileKind(path: file.path).isPlayable {
            indexByStem[stem(of: file.path)] = groups.count
            groups.append(RemoteFileGroup(file: file))
        }

        for file in files where !FileKind(path: file.path).isPlayable {
            if let index = owner(of: file.path, in: indexByStem) {
                groups[index].sidecars.append(file)
            } else {
                orphans.append(file)
            }
        }

        return groups + orphans.map { RemoteFileGroup(file: $0) }
    }

    /// Walks off one trailing `.suffix` at a time, so a language-tagged `ep-01.zh-CN.vtt`
    /// finds `ep-01.mp3` the same way a plain `ep-01.vtt` does.
    private static func owner(of path: String, in indexByStem: [String: Int]) -> Int? {
        var candidate = stem(of: path)
        while !candidate.isEmpty {
            if let index = indexByStem[candidate] { return index }
            let next = (candidate as NSString).deletingPathExtension
            if next == candidate { return nil }
            candidate = next
        }
        return nil
    }

    private static func stem(of path: String) -> String {
        (path as NSString).deletingPathExtension
    }
}
