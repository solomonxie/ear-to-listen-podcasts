import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var providers: [ProviderRecord] = []
    @Published var testResults: [String: ConnectionTestResult] = [:]
    @Published var spotifyClientID: String = ""
    @Published var aiKeys: [AiKey] = []
    @Published var aiKeyStrategy: AiKeyStrategy = .sequential
    @Published var errorMessage: String?
    @Published var backupStatusMessage: String?

    /// Not private: `AiKeyStore` reads the same Keychain entry to migrate it into the
    /// new multi-key list the first time that's read after this feature shipped.
    /// `nonisolated` so that off-main-actor code (sync runs in the background) can read
    /// this constant without hopping to the main actor for a value that never changes.
    nonisolated static let openAIAPIKeyKey = "openai.apiKey"

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let aiKeyStore = AiKeyStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let credentials = CredentialStore()
    private let backupService = BackupService()

    var hasActiveRemoteProvider: Bool {
        providers.contains { $0.type == S3Provider.providerType && $0.isActive }
    }

    func load() {
        do {
            providers = try providerStore.all()
            spotifyClientID = try credentials.get(SpotifyImportSource.clientIDKey) ?? ""
            aiKeys = try aiKeyStore.all()
            aiKeyStrategy = AiRouter.strategy
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Tests the key with one real, cheap request before persisting it, same flow as
    /// adding an S3 connection tests the bucket first. Throws (rather than going
    /// through `errorMessage`) so the add-key sheet can show the failure inline.
    /// The test call goes through the *chosen* model, so a mistyped custom name fails
    /// here rather than silently on every sync afterwards.
    func addAiKey(vendor: AiVendor, model: String?, secret: String) async throws {
        _ = try await AiRouter.runChatCompletion(
            vendor: vendor, apiKey: secret, model: model,
            messages: [ChatMessage(role: .user, content: "Reply with \"ok\".")]
        )
        try aiKeyStore.add(vendor: vendor, model: model, secret: secret)
        aiKeys = try aiKeyStore.all()
    }

    func setAiKeyModel(_ key: AiKey, model: String?) {
        do {
            try aiKeyStore.setModel(id: key.id, model: model)
            aiKeys = try aiKeyStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAiKey(_ key: AiKey) {
        do {
            try aiKeyStore.remove(id: key.id)
            aiKeys = try aiKeyStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveAiKey(_ key: AiKey, direction: Int) {
        do {
            try aiKeyStore.move(id: key.id, direction: direction)
            aiKeys = try aiKeyStore.all()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAiKeyStrategy(_ strategy: AiKeyStrategy) {
        aiKeyStrategy = strategy
        AiRouter.strategy = strategy
    }

    @discardableResult
    func addS3Provider(accessKeyId: String, secretAccessKey: String, region: String, bucket: String, keyPrefix: String) -> ProviderRecord? {
        let id = UUID().uuidString
        let settings = [
            "accessKeyId": accessKeyId,
            "secretAccessKey": secretAccessKey,
            "region": region,
            "bucket": bucket,
            "keyPrefix": keyPrefix,
        ]
        do {
            try ProviderManager.shared.saveSettings(settings, forProviderID: id)
            let record = ProviderRecord(
                id: id,
                type: S3Provider.providerType,
                label: bucket,
                configJSON: "",
                isActive: true,
                createdAt: Date()
            )
            try providerStore.upsert(record)
            // A bucket is where this user's data lives, so the app's own data starts
            // going there too — transcripts and hand edits are expensive to lose and
            // aren't rebuilt by a resync.
            AutoBackup.shared.enableForNewRemote()
            load()
            // Connecting a bucket to a device with nothing on it is the other half of the
            // reinstall story: the app data may be sitting in that bucket too.
            Task { await FirstRunRestore.runAfterConnectingRemote() }
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Episodes the listener picked one by one out of Files. They all land in a single
    /// source rather than one per pick, so importing twice doesn't leave two half-full
    /// entries in the list — and an episode already imported is left as it is, keeping the
    /// path its track, edits and transcript are keyed by.
    ///
    /// `urls` are security-scoped from a `.fileImporter`; access is only needed long
    /// enough to mint each bookmark.
    @discardableResult
    func addPickedFiles(_ urls: [URL]) -> ProviderRecord? {
        let existing = providers.first {
            $0.type == LocalFilesProvider.providerType
                && LocalFilesProvider.entries(in: ProviderManager.shared.settings(for: $0.id) ?? [:]) != nil
        }
        let id = existing?.id ?? UUID().uuidString
        var entries = existing.flatMap { LocalFilesProvider.entries(in: ProviderManager.shared.settings(for: $0.id) ?? [:]) } ?? []
        var bookmarks = Set(entries.map(\.bookmark))

        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData().base64EncodedString(), !bookmarks.contains(bookmark) else { continue }
            let path = LocalFileEntry.uniquePath(for: url.lastPathComponent, avoiding: Set(entries.map(\.path)))
            entries.append(LocalFileEntry(path: path, bookmark: bookmark))
            bookmarks.insert(bookmark)
        }
        guard !entries.isEmpty else { return nil }

        do {
            try ProviderManager.shared.saveSettings(
                [LocalFileEntry.settingsKey: try LocalFilesProvider.encode(entries)], forProviderID: id
            )
            let record = ProviderRecord(
                id: id,
                type: LocalFilesProvider.providerType,
                label: "Files",
                configJSON: "",
                isActive: true,
                createdAt: existing?.createdAt ?? Date()
            )
            try providerStore.upsert(record)
            ProviderManager.shared.invalidate(providerID: id)
            load()
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// `folderURL` must be a security-scoped URL from a `.fileImporter`/document
    /// picker; access is only needed long enough to mint the bookmark.
    @discardableResult
    func addLocalProvider(folderURL: URL) -> ProviderRecord? {
        let id = UUID().uuidString
        guard folderURL.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access that folder."
            return nil
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        do {
            let bookmark = try folderURL.bookmarkData()
            try ProviderManager.shared.saveSettings(["bookmark": bookmark.base64EncodedString()], forProviderID: id)
            let record = ProviderRecord(
                id: id,
                type: LocalFilesProvider.providerType,
                label: folderURL.lastPathComponent,
                configJSON: "",
                isActive: true,
                createdAt: Date()
            )
            try providerStore.upsert(record)
            load()
            return record
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ record: ProviderRecord) {
        do {
            try providerStore.delete(id: record.id)
            try ProviderManager.shared.deleteSettings(forProviderID: record.id)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleActive(_ record: ProviderRecord) {
        do {
            var updated = record
            updated.isActive.toggle()
            try providerStore.upsert(updated)
            ProviderManager.shared.invalidate(providerID: record.id)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testConnection(_ record: ProviderRecord) {
        Task {
            do {
                let provider = try ProviderManager.shared.provider(for: record)
                testResults[record.id] = await provider.testConnection()
            } catch {
                testResults[record.id] = ConnectionTestResult(isSuccess: false, message: error.localizedDescription)
            }
        }
    }

    func saveSpotifyClientID() {
        do {
            try credentials.set(spotifyClientID, forKey: SpotifyImportSource.clientIDKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Builds the export document lazily, right when the export sheet is about to
    /// show, so it reflects the current DB rather than a stale snapshot from `load()`.
    func makeExportDocument() -> BackupDocument? {
        do {
            return BackupDocument(data: try backupService.archive(try backupService.makeSnapshot()))
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// `url` comes from a `.fileImporter` picker, so it's security-scoped. The archive is
    /// restored into a library of its own and switched to — the one that was here is kept
    /// as a file, and `undoRestore()` puts it back.
    func importSnapshot(from url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try DatasetRestore.restore(try Data(contentsOf: url))
            backupStatusMessage = summarize(result)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The library the last restore replaced, while it's still on the phone to go back to.
    var replacedLibraryAt: Date? { DatasetRestore.previousLibrary?.at }

    func undoRestore() {
        do {
            try DatasetRestore.undo()
            backupStatusMessage = "Put back the library from before the restore."
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summarize(_ result: BackupImportResult) -> String {
        var message = "Restored \(result.playlistsImported) playlist\(result.playlistsImported == 1 ? "" : "s")"
        // Said rather than swallowed, but said as a wait and not a loss: these land by
        // themselves once a sync has fetched the episodes they name.
        if result.awaitingSync > 0 {
            message += ", \(result.awaitingSync) item\(result.awaitingSync == 1 ? "" : "s") waiting for the next sync"
        }
        return message + "."
    }
}
