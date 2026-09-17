import Foundation

/// What a file in someone's storage actually is, as far as this app is concerned.
///
/// A bucket is the user's own, so it holds whatever they keep there — this app's backup, a
/// transcript sidecar, cover art, a stray note. Only audio is ever an episode. Everything
/// else is shown for what it is rather than offered as something to play, which is the
/// difference between "browsing my podcasts" and "browsing a bucket that happens to be
/// full of files".
enum FileKind: Sendable, Equatable {
    case audio
    /// A transcript sitting beside an episode — see `TranscriptFile`.
    case transcript
    case text
    case archive
    case image
    case other

    /// The one list that decides what syncs as an episode.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"]

    private static let transcriptExtensions: Set<String> = ["vtt", "srt", "lrc"]
    private static let textExtensions: Set<String> = [
        "txt", "json", "md", "markdown", "log", "csv", "tsv", "xml", "yaml", "yml",
        "ini", "conf", "cfg", "nfo", "cue", "html", "rtf",
    ]
    private static let archiveExtensions: Set<String> = ["zip", "gz", "tgz", "tar", "7z", "rar", "bz2"]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
    ]

    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case _ where Self.audioExtensions.contains(ext): self = .audio
        case _ where Self.transcriptExtensions.contains(ext): self = .transcript
        case _ where Self.textExtensions.contains(ext): self = .text
        case _ where Self.archiveExtensions.contains(ext): self = .archive
        case _ where Self.imageExtensions.contains(ext): self = .image
        default: self = .other
        }
    }

    var isPlayable: Bool { self == .audio }

    /// Deliberately narrower than `!isPlayable`, and the only rule allowed to delete
    /// anything: a file with no extension may well still be audio — the bundled demo
    /// clips are exactly that — so nothing is removed on suspicion. Only kinds positively
    /// recognised as something else qualify.
    var isKnownNonAudio: Bool {
        switch self {
        case .transcript, .text, .archive, .image: return true
        case .audio, .other: return false
        }
    }

    /// Whether opening it should show its contents rather than just its size and date.
    var isReadableAsText: Bool { self == .text || self == .transcript }

    var symbol: String {
        switch self {
        case .audio: return "waveform"
        case .transcript: return "captions.bubble"
        case .text: return "doc.text"
        case .archive: return "shippingbox"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    var displayName: String {
        switch self {
        case .audio: return "Episode"
        case .transcript: return "Transcript"
        case .text: return "Text file"
        case .archive: return "Archive"
        case .image: return "Image"
        case .other: return "File"
        }
    }
}
