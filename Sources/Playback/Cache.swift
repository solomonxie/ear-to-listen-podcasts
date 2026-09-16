import CryptoKit
import Foundation

/// LRU disk cache for streamed audio, keyed by provider + file path. Playback always tries
/// the cache before hitting the network; a cache miss streams from the provider's URL directly
/// (no playback delay) while a copy downloads in the background for next time.
actor AudioCache {
    static let shared = AudioCache()

    let directory: URL
    private let maxSizeBytes: Int64

    init(directory: URL? = nil, maxSizeBytes: Int64 = 1_000_000_000) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioCache", isDirectory: true)
        self.maxSizeBytes = maxSizeBytes
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Returns the cached copy if present, bumping its modification date so LRU eviction skips it.
    func cachedURL(providerID: String, filePath: String) -> URL? {
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
    /// `DownloadsView` — the track itself stays synced, just its local copy goes.
    func invalidate(providerID: String, filePath: String) {
        try? FileManager.default.removeItem(at: fileURL(providerID: providerID, filePath: filePath))
    }

    /// Size of the cached copy if one exists — `nil` means not downloaded. Doesn't bump the
    /// LRU access date the way `cachedURL` does, since just listing what's downloaded
    /// shouldn't protect an entry from eviction the way actually playing it does.
    func cachedSize(providerID: String, filePath: String) -> Int64? {
        let url = fileURL(providerID: providerID, filePath: filePath)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize.map(Int64.init)
    }

    private func fileURL(providerID: String, filePath: String) -> URL {
        directory.appendingPathComponent(cacheKey(providerID: providerID, filePath: filePath))
    }

    private func cacheKey(providerID: String, filePath: String) -> String {
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
