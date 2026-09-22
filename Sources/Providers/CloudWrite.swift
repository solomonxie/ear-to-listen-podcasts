import Foundation

/// The one rule every write to someone's storage has to obey: **never write over their
/// audio.**
///
/// The episodes in a bucket are the only thing in it this app can't rebuild — a transcript
/// can be run again, a library can be restored from a snapshot, an overwritten MP3 is
/// gone. So the rule is about *overwriting*, not about audio: an episode the listener
/// picked out of Files goes up through `CloudProvider.uploadEpisode`, which takes a key
/// nothing occupies and refuses one that's taken.
///
/// Sidecars sit in the same folder as the audio and share its basename — `ep-01.mp3` →
/// `ep-01.vtt` — so the folder is deliberately *not* what's checked. The extension is.
enum CloudWrite {
    struct WouldOverwriteAudioError: Error, LocalizedError {
        let path: String
        var errorDescription: String? {
            "Refused to write over \((path as NSString).lastPathComponent) — that's an episode, and this app never overwrites audio."
        }
    }

    struct NotAnEpisodeError: Error, LocalizedError {
        let path: String
        var errorDescription: String? {
            "\((path as NSString).lastPathComponent) isn't an audio file, so it isn't something to add as an episode."
        }
    }

    struct EmptyPathError: Error, LocalizedError {
        var errorDescription: String? { "Refused to write to an empty path." }
    }

    /// Runs inside `CloudProvider.upload`, which is every write the app makes on its own —
    /// a sidecar, a library archive. Returns the path so it reads as one step:
    /// `let key = try CloudWrite.checked(path)`.
    @discardableResult
    static func checked(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw EmptyPathError() }
        guard !FileKind(path: path).isPlayable else { throw WouldOverwriteAudioError(path: path) }
        return path
    }

    /// The mirror image, for the one write that is audio: it has to *be* audio, and
    /// `uploadEpisode` checks the key is free before it writes.
    @discardableResult
    static func checkedEpisode(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw EmptyPathError() }
        guard FileKind(path: path).isPlayable else { throw NotAnEpisodeError(path: path) }
        return path
    }

    /// A name no one else in the folder has. Two picks called `ep-01.mp3` are two
    /// episodes, not one to drop — and renaming the newcomer is the only way to keep both
    /// without touching the file already there.
    static func availableName(for name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 2... {
            let candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }
}
