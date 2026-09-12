import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var providers: [ProviderRecord] = []
    @Published var testResults: [String: ConnectionTestResult] = [:]
    @Published var spotifyClientID: String = ""
    @Published var errorMessage: String?

    private let providerStore = ProviderStore(dbQueue: DatabaseManager.shared.dbQueue)
    private let credentials = CredentialStore()

    func load() {
        do {
            providers = try providerStore.all()
            spotifyClientID = try credentials.get(SpotifyImportSource.clientIDKey) ?? ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addS3Provider(label: String, accessKeyId: String, secretAccessKey: String, region: String, bucket: String) {
        let id = UUID().uuidString
        let settings = [
            "accessKeyId": accessKeyId,
            "secretAccessKey": secretAccessKey,
            "region": region,
            "bucket": bucket,
        ]
        do {
            try ProviderManager.shared.saveSettings(settings, forProviderID: id)
            let record = ProviderRecord(
                id: id,
                type: S3Provider.providerType,
                label: label.isEmpty ? bucket : label,
                configJSON: "",
                isActive: true,
                createdAt: Date()
            )
            try providerStore.upsert(record)
            load()
        } catch {
            errorMessage = error.localizedDescription
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
}
