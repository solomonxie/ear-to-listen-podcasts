import Foundation
import UniformTypeIdentifiers

/// Episodes the listener picked out of Files, written into the bucket folder they were
/// looking at and queued like anything else a listing found.
///
/// The two halves matter equally: the file has to reach the bucket (so it's backed up,
/// and there on every other device), and the library has to learn about it without a
/// whole-bucket re-listing. Enqueueing the one key directly is what makes an upload feel
/// immediate on a bucket with thousands of files in it.
struct EpisodeUpload {
    struct Outcome {
        var uploaded: [String] = []
        var failures: [String] = []

        var summary: String? {
            var parts: [String] = []
            if !uploaded.isEmpty {
                parts.append("Uploaded \(uploaded.count) episode\(uploaded.count == 1 ? "" : "s") — importing in the background.")
            }
            parts += failures
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    let provider: CloudProvider
    let providerID: String
    /// The folder on screen, as a whole path. `nil` means the level the connection itself
    /// starts at.
    let folder: String?
    var jobStore = SyncJobStore(dbQueue: DatabaseManager.shared.dbQueue)

    /// `taken` is what the caller can already see in this folder — the live listing. A
    /// name that collides is renamed rather than dropped or overwritten; a name that
    /// collides with something the listing didn't show is caught by `uploadEpisode`.
    func run(_ urls: [URL], avoiding taken: Set<String>) async -> Outcome {
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
                // Mapped rather than read: an episode is tens of megabytes and this runs
                // on a phone.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try await provider.uploadEpisode(data, toPath: prefix + name, contentType: Self.contentType(for: name))
                taken.insert(name)
                outcome.uploaded.append(name)
                do {
                    try jobStore.enqueue(
                        providerID: providerID, filePath: prefix + name, displayName: name,
                        sizeBytes: Int64(data.count)
                    )
                } catch {
                    // It's in the bucket, which is the part that can't be redone — the
                    // next listing pass picks it up.
                    outcome.failures.append("\(name) is uploaded but the queue is full — it'll import on the next sync.")
                }
            } catch {
                outcome.failures.append("\(name): \(describeCloudError(error))")
            }
        }

        if !outcome.uploaded.isEmpty {
            // The same hop `SyncEngine.sync` ends on: it refreshes the queue and wakes the
            // drain loop, so nothing here needs the main actor.
            NotificationCenter.default.post(name: .syncQueueDidChange, object: nil)
        }
        return outcome
    }

    private static func contentType(for name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
