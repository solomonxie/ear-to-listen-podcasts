import CryptoKit
import Foundation

/// LRU disk store for downloaded audio, keyed by provider + file path. Playback always
/// tries it before hitting the network; a miss streams from the provider's URL directly
/// (no playback delay) while a copy downloads in the background for next time.
///
/// **In `Documents/Downloads`, not `Caches`.** These are the listener's episodes, off
/// their own storage — they should be visible in the Files app and copyable off the phone
/// like any other download, which `Caches` is not (`UIFileSharingEnabled` only exposes
/// `Documents`). It also means iOS won't quietly purge them under storage pressure, which
/// `Caches` can do mid-flight to an episode someone downloaded deliberately.
///
/// The trade is that they now count against the device's storage until evicted, which is
/// what `maxSizeBytes` and the Downloaded playlist's swipe-to-delete are for. They're
/// excluded from iCloud backup: a gigabyte of re-downloadable audio has no business in
/// someone's iCloud quota, and the app's own backup has always refused to carry audio.
actor AudioCache {
    static let shared = AudioCache()

    let directory: URL
    private let maxSizeBytes: Int64
    /// Where entries lived before they were visible. Read on a miss, never written.
    private let legacyDirectory: URL

    init(directory: URL? = nil, maxSizeBytes: Int64 = 1_000_000_000) {
        self.directory = directory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        self.legacyDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioCache", isDirectory: true)
        self.maxSizeBytes = maxSizeBytes
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directoryURL = self.directory
        try? directoryURL.setResourceValues(excluded)
    }

    /// Returns the cached copy if present, bumping its modification date so LRU eviction skips it.
    func cachedURL(providerID: String, filePath: String) -> URL? {
        adoptLegacyEntryIfPresent(providerID: providerID, filePath: filePath)
        let url = fileURL(providerID: providerID, filePath: filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Downloads `remoteURL` into the cache, evicting least-recently-used entries first if the
    /// new file would push the cache over budget.
    @discardableResult
    func store(remoteURL: URL, providerID: String, filePath: String) async throws -> URL {
        let destination = fileURL(providerID: providerID, filePath: filePath)
        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        evictIfNeeded()
        return destination
    }

    /// Drops a cached copy so the next play re-fetches it — used when a stream URL turns out
    /// to be stale (e.g. an expired presigned URL), or when the user removes it from
    /// the Downloaded playlist — the track itself stays synced, just its local copy goes.
    func invalidate(providerID: String, filePath: String) {
        // Every name it could be under — an entry that was never touched since the move
        // out of `Caches` is still sitting there, and "remove this download" has to mean it.
        try? FileManager.default.removeItem(at: fileURL(providerID: providerID, filePath: filePath))
        for legacy in legacyURLs(providerID: providerID, filePath: filePath) {
            try? FileManager.default.removeItem(at: legacy)
        }
    }

    /// Size of the cached copy if one exists — `nil` means not downloaded. Doesn't bump the
    /// LRU access date the way `cachedURL` does, since just listing what's downloaded
    /// shouldn't protect an entry from eviction the way actually playing it does.
    func cachedSize(providerID: String, filePath: String) -> Int64? {
        adoptLegacyEntryIfPresent(providerID: providerID, filePath: filePath)
        let url = fileURL(providerID: providerID, filePath: filePath)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize.map(Int64.init)
    }

    /// `ep-01~3f2a9c11.mp3` — the episode's own filename, plus enough of the key to keep
    /// two files of the same name apart.
    ///
    /// The name matters now that this folder is one the listener opens: a directory of
    /// 400 bare SHA-256 hashes is visible and useless. The suffix is what makes it safe —
    /// two buckets can both hold `ep-01.mp3`, and the same name in the same flat folder
    /// would have one silently serving the other's audio.
    ///
    /// The extension is kept because AVFoundation decides what a file *is* largely from
    /// it: an extension-less entry can play and still refuse to transcribe, since
    /// `AVAssetReader` is what the transcriber decodes with.
    nonisolated static func fileName(providerID: String, filePath: String) -> String {
        let key = cacheKey(providerID: providerID, filePath: filePath)
        let stem = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (filePath as NSString).pathExtension.lowercased()
        let safeStem = stem
            .components(separatedBy: CharacterSet(charactersIn: "/\\:~"))
            .joined(separator: "-")
            .nilIfEmpty ?? "episode"
        let base = "\(safeStem)~\(key.prefix(8))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private func fileURL(providerID: String, filePath: String) -> URL {
        directory.appendingPathComponent(Self.fileName(providerID: providerID, filePath: filePath))
    }

    /// Every name an entry has been written under, newest scheme last. Each is moved into
    /// place on first touch rather than re-downloaded, so an existing download survives
    /// both the move out of `Caches` and the rename.
    private func legacyURLs(providerID: String, filePath: String) -> [URL] {
        let key = Self.cacheKey(providerID: providerID, filePath: filePath)
        let ext = (filePath as NSString).pathExtension.lowercased()
        let hashed = ext.isEmpty ? key : "\(key).\(ext)"
        return [
            legacyDirectory.appendingPathComponent(hashed),
            legacyDirectory.appendingPathComponent(key),
            directory.appendingPathComponent(hashed),
            directory.appendingPathComponent(key),
        ]
    }

    private func adoptLegacyEntryIfPresent(providerID: String, filePath: String) {
        let current = fileURL(providerID: providerID, filePath: filePath)
        guard !FileManager.default.fileExists(atPath: current.path) else { return }
        for legacy in legacyURLs(providerID: providerID, filePath: filePath)
        where legacy != current && FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
            return
        }
    }

    /// Which tracks are downloaded, from **one** directory listing.
    ///
    /// Asking `cachedURL` per track — which Home used to do — costs four filesystem calls
    /// each (two for the legacy check, one `fileExists`, one attribute *write*), so a
    /// 5,000-track library meant 20,000 syscalls and 5,000 writes every time the shelf
    /// refreshed. Worse, `cachedURL` bumps the LRU date, so merely listing what was
    /// downloaded made every entry look freshly played and quietly defeated eviction.
    ///
    /// Returns the set of cache keys present; pair it with `isCached(_:providerID:filePath:)`,
    /// which is pure computation.
    func cachedKeys() -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return Set(entries.map(\.lastPathComponent))
    }

    /// No I/O — just the name, checked against a set from `cachedKeys()`.
    nonisolated func isCached(_ keys: Set<String>, providerID: String, filePath: String) -> Bool {
        keys.contains(Self.fileName(providerID: providerID, filePath: filePath))
    }

    private func cacheKey(providerID: String, filePath: String) -> String {
        Self.cacheKey(providerID: providerID, filePath: filePath)
    }

    nonisolated static func cacheKey(providerID: String, filePath: String) -> String {
        let hash = SHA256.hash(data: Data("\(providerID)|\(filePath)".utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func evictIfNeeded() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var items = entries.compactMap { url -> (url: URL, size: Int64, accessedAt: Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }

        var totalSize = items.reduce(0) { $0 + $1.size }
        guard totalSize > maxSizeBytes else { return }

        items.sort { $0.accessedAt < $1.accessedAt }
        for item in items {
            guard totalSize > maxSizeBytes else { break }
            try? FileManager.default.removeItem(at: item.url)
            totalSize -= item.size
        }
    }
}
