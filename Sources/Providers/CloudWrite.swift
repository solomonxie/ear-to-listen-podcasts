import Foundation

/// The one rule every write to someone's storage has to obey: **never write over their
/// audio.**
///
/// The episodes in a bucket are the only thing in it this app can't rebuild — a transcript
/// can be run again, a library can be restored from a snapshot, an overwritten MP3 is
/// gone. Today's two writers (a transcript sidecar, the library backup) both build their
/// own key and neither can reach an audio path, but "neither of them currently does" is a
/// fact about today's call sites, not a property of the system. This makes it one.
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

    struct EmptyPathError: Error, LocalizedError {
        var errorDescription: String? { "Refused to write to an empty path." }
    }

    /// Call at the top of every `CloudProvider.upload`. Returns the path so it reads as
    /// one step: `let key = try CloudWrite.checked(path)`.
    @discardableResult
    static func checked(_ path: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw EmptyPathError() }
        guard !FileKind(path: path).isPlayable else { throw WouldOverwriteAudioError(path: path) }
        return path
    }
}
