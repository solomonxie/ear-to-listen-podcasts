import Foundation
import GRDB

/// The bucket and AI key from `.env.demo`, which a non-Release build copies into the
/// bundle as `DemoSecrets.plist` (`scripts/demo-secrets.sh`). Release neither carries the
/// file nor reads it: demo mode there runs on the bundled library alone.
enum DemoSecrets {
    private static let values: [String: String] = {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "DemoSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return plist.filter { !$0.value.isEmpty }
        #else
        return [:]
        #endif
    }()

    static func apply(to dbQueue: DatabaseQueue) {
        addSource(to: dbQueue)
        addAiKey(to: dbQueue)
    }

    /// Takes the Keychain entries the sample library added with it.
    static func forget(in dbQueue: DatabaseQueue) {
        let providerIDs = (try? ProviderStore(dbQueue: dbQueue).all().map(\.id)) ?? []
        for id in providerIDs { try? ProviderManager.shared.deleteSettings(forProviderID: id) }
        let keyIDs = (try? dbQueue.read { db in try String.fetchAll(db, sql: "SELECT id FROM aiKeys") }) ?? []
        for id in keyIDs { try? CredentialStore().delete(AiKeyStore.secretKey(id: id)) }
    }

    private static func addSource(to dbQueue: DatabaseQueue) {
        guard let type = values["DEMO_SOURCE_TYPE"], let bucket = values["DEMO_SOURCE_BUCKET"] else { return }
        let settings: [String: String] = [
            "bucket": bucket,
            "region": values["DEMO_SOURCE_REGION"],
            "accessKeyId": values["DEMO_SOURCE_ACCESS_KEY_ID"],
            "secretAccessKey": values["DEMO_SOURCE_SECRET_ACCESS_KEY"],
            "keyPrefix": values["DEMO_SOURCE_FOLDER"],
        ].compactMapValues { $0 }
        let record = ProviderRecord(
            id: UUID().uuidString, type: type, label: values["DEMO_SOURCE_LABEL"] ?? "Demo Bucket",
            configJSON: "", isActive: true, createdAt: Date()
        )
        do {
            try ProviderManager.shared.saveSettings(settings, forProviderID: record.id)
            try dbQueue.write { db in try record.insert(db) }
        } catch {
            try? ProviderManager.shared.deleteSettings(forProviderID: record.id)
        }
    }

    private static func addAiKey(to dbQueue: DatabaseQueue) {
        guard let vendor = values["DEMO_AI_VENDOR"].flatMap(AiVendor.init(rawValue:)),
              let secret = values["DEMO_AI_KEY"] else { return }
        _ = try? AiKeyStore(dbQueue: dbQueue).add(vendor: vendor, model: values["DEMO_AI_MODEL"], secret: secret)
    }
}
