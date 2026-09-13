import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var providers: [ProviderRecord] = []
    @Published var testResults: [String: ConnectionTestResult] = [:]
    @Published var spotifyClientID: String = ""
    @Published var openAIAPIKey: String = ""
    @Published var errorMessage: String?

    /// Not private: `Sources/Library/ContentAnalyzer.swift` reads the same Keychain entry.
    /// `nonisolated` so that off-main-actor code (sync runs in the background) can read this
    /// constant without hopping to the main actor for a value that never changes.
    nonisolated static let openAIAPIKeyKey = "openai.apiKey"

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let credentials = CredentialStore()

    func load() {
        do {
            providers = try providerStore.all()
            spotifyClientID = try credentials.get(SpotifyImportSource.clientIDKey) ?? ""
            openAIAPIKey = try credentials.get(Self.openAIAPIKeyKey) ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func saveOpenAIAPIKey() {
        do {
            if openAIAPIKey.isEmpty {
                try credentials.delete(Self.openAIAPIKeyKey)
            } else {
                try credentials.set(openAIAPIKey, forKey: Self.openAIAPIKeyKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
