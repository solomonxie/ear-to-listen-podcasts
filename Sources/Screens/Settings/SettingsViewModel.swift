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
    @Published var isBackupBusy = false

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
    func addAiKey(vendor: AiVendor, secret: String) async throws {
        _ = try await AiRouter.runChatCompletion(vendor: vendor, apiKey: secret, messages: [
            ChatMessage(role: .user, content: "Reply with \"ok\"."),
        ])
        try aiKeyStore.add(vendor: vendor, secret: secret)
        aiKeys = try aiKeyStore.all()
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
            AutoBackup.shared.markChanged()
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

    /// `url` comes from a `.fileImporter` picker, so it's security-scoped.
    func importSnapshot(from url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try backupService.apply(try backupService.unarchive(try Data(contentsOf: url)))
            backupStatusMessage = summarize(result)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func backupToRemote() {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        Task {
            defer { isBackupBusy = false }
            do {
                try await backupService.backupToRemote()
                backupStatusMessage = "Backed up to remote."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func restoreFromRemote() {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        Task {
            defer { isBackupBusy = false }
            do {
                let result = try await backupService.restoreFromRemote()
                backupStatusMessage = summarize(result)
                load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func summarize(_ result: BackupImportResult) -> String {
        var message = "Restored \(result.playlistsImported) playlist\(result.playlistsImported == 1 ? "" : "s")"
        if result.tracksUnmatched > 0 {
            message += ", \(result.tracksUnmatched) track\(result.tracksUnmatched == 1 ? "" : "s") not synced yet"
        }
        return message + "."
    }
}
