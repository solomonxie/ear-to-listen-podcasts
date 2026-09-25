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
        providers.contains { $0.cloudKind != nil && $0.isActive }
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

    /// A connected bucket, in whichever cloud. `settings` is that cloud's own credential
    /// (`CloudSourceKind.credential`) plus `bucket`/`keyPrefix`, and it goes to the
    /// Keychain — the database row holds nothing secret.
    @discardableResult
    func addCloudProvider(kind: CloudSourceKind, label: String, settings: [String: String]) -> ProviderRecord? {
        guard let record = addProvider(type: kind.providerType, label: label, settings: settings) else {
            return nil
        }
        // A bucket is where this user's data lives, so the app's own data starts
        // going there too — transcripts and hand edits are expensive to lose and
        // aren't rebuilt by a resync.
        AutoBackup.shared.enableForNewRemote()
        // Connecting a bucket to a device with nothing on it is the other half of the
        // reinstall story: the app data may be sitting in that bucket too.
        Task { await FirstRunRestore.runAfterConnectingRemote() }
        return record
    }

    /// A folder picked out of Files, connected as a source in its own right. Neither of
    /// the two things a new bucket triggers applies: a folder on this phone is no place
    /// to keep a backup of the phone, and there's nothing in it to restore from.
    @discardableResult
    func addLocalFolder(label: String, settings: [String: String]) -> ProviderRecord? {
        addProvider(type: LocalFilesProvider.providerType, label: label, settings: settings)
    }

    private func addProvider(type: String, label: String, settings: [String: String]) -> ProviderRecord? {
        let id = UUID().uuidString
        do {
            try ProviderManager.shared.saveSettings(settings, forProviderID: id)
            let record = ProviderRecord(
                id: id,
                type: type,
                label: label,
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
            // Its episodes went with it (the rows cascade), so titles that were only
            // numbered to tell them apart from *those* have nothing left to disambiguate.
            // Nothing else runs this pass on a delete, which is why a disconnected source
            // used to leave "(2)" on every episode it had collided with.
            if (try? TrackStore(dbQueue: DatabaseManager.shared.dbQueue).numberDuplicateTitles()) ?? 0 > 0 {
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            }
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

    /// Clears every on-device copy, after a recovery archive has been written by itself —
    /// to Files, and to iCloud and the bucket wherever they're connected. Nothing is
    /// picked or saved by hand: the one irreversible button shouldn't depend on getting a
    /// save sheet right, and the copies that outlive this phone are the off-device ones
    /// anyway.
    func removeAllAppData() async {
        do {
            let savedTo = try await AutoBackup.shared.backUpBeforeDeletion()
            let stagingURL = URL.applicationSupportDirectory.appending(path: "empty-library.sqlite")
            removeDatabase(at: stagingURL)
            defer { removeDatabase(at: stagingURL) }
            let emptyDatabase = try DatabaseManager.makeDataset(at: stagingURL)
            try DatabaseManager.shared.replaceContents(with: emptyDatabase)

            try credentials.deleteAll()
            ProviderManager.shared.invalidateAll()
            await AudioCache.shared.removeAll()
            removeAppSupportData()
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
            // Erasing on purpose is not a fresh install. Without this, wiping the defaults
            // clears the first-run flag too, and the next launch sees an empty library,
            // goes to iCloud for the newest archive — the recovery copy just written — and
            // puts the speakers and edits straight back.
            FirstRunRestore.markDone()
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
            load()
            backupStatusMessage = savedTo
        } catch {
            errorMessage = error.localizedDescription
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

    private func removeAppSupportData() {
        let manager = FileManager.default
        let support = URL.applicationSupportDirectory
        for name in ["SpeakerPhotos", "Artwork", "snapshots", "change-log", "pending-restore.zip"] {
            try? manager.removeItem(at: support.appending(path: name))
        }
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
}
