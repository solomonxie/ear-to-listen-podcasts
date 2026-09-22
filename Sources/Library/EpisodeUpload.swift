import Foundation
import UniformTypeIdentifiers

/// Episodes the listener picked out of Files, on their way into the bucket folder they
/// were looking at.
///
/// Queued, not uploaded on the spot: an episode is tens of megabytes, and the queue is
/// already the thing that says what's in flight, pauses it, paces it and retries it. So
/// picking files only writes a job per file (`queue`), and the drain loop does the
/// sending (`send`) before the same job imports what it just put there.
struct EpisodeUpload {
    struct Outcome {
        var queued: [String] = []
        var failures: [String] = []

        var summary: String? {
            var parts: [String] = []
            if !queued.isEmpty {
                parts.append("Queued \(queued.count) episode\(queued.count == 1 ? "" : "s") — uploading in the background.")
            }
            parts += failures
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    struct MissingFileError: Error, LocalizedError {
        let name: String
        var errorDescription: String? { "\(name) isn't where it was when you picked it." }
    }

    let provider: CloudProvider
    let providerID: String
    /// The folder on screen, as a whole path. `nil` means the level the connection itself
    /// starts at.
    let folder: String?
    var jobStore = SyncJobStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// `taken` is what the caller can already see in this folder — the live listing. A
    /// name that collides is renamed rather than dropped or overwritten; a name that
    /// collides with something the listing didn't show is caught by `uploadEpisode` when
    /// the job runs.
    func queue(_ urls: [URL], avoiding taken: Set<String>) -> Outcome {
        var outcome = Outcome()
        guard provider.isWritable else {
            outcome.failures.append(CloudProviderError.readOnly(provider.type).localizedDescription)
            return outcome
        }
        let prefix = CloudFolderPath.normalized(folder) ?? provider.rootFolder ?? ""
        var taken = taken

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let name = CloudWrite.availableName(for: url.lastPathComponent, avoiding: taken)
            do {
                // Minted while the picker's grant is still open — the job may not run for
                // minutes, or until the next launch.
                let bookmark = try url.bookmarkData().base64EncodedString()
                try jobStore.enqueue(
                    providerID: providerID, filePath: prefix + name, displayName: name,
                    sizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                    uploadBookmark: bookmark
                )
                taken.insert(name)
                outcome.queued.append(name)
            } catch {
                outcome.failures.append("\(name): \(error.localizedDescription)")
            }
        }

        if !outcome.queued.isEmpty {
            // The same hop `SyncEngine.sync` ends on: it refreshes the queue and wakes the
            // drain loop, so nothing here needs the main actor.
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        }
        return outcome
    }

    /// The upload half of a queued job, run by `SyncEngine.perform` before it imports.
    /// A file already at that key is refused rather than replaced — see `CloudWrite`.
    static func send(_ job: SyncJob, provider: CloudProvider) async throws {
        guard let encoded = job.uploadBookmark, let bookmarkData = Data(base64Encoded: encoded) else {
            throw MissingFileError(name: job.displayName)
        }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Mapped rather than read: an episode is tens of megabytes and this runs on a phone.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw MissingFileError(name: job.displayName)
        }
        try await provider.uploadEpisode(
            data, toPath: job.filePath, contentType: contentType(for: job.displayName)
        )
    }

    private static func contentType(for name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
