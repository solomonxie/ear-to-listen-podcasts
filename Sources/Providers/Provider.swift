import Foundation

struct CloudFile: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var sizeBytes: Int64?
    var mimeType: String?
    var modifiedAt: Date?
}

struct ConnectionTestResult {
    var isSuccess: Bool
    var message: String?
}

struct CloudProviderConfig: Codable {
    var id: String
    var type: String
    var label: String
    var settings: [String: String]
}

protocol CloudProvider {
    var type: String { get }
    func listFiles(inFolder folderID: String?) async throws -> [CloudFile]
    func metadata(forFileID fileID: String) async throws -> CloudFile
    func streamURL(forFileID fileID: String) async throws -> URL
    func testConnection() async -> ConnectionTestResult
}

final class CloudProviderRegistry {
    static let shared = CloudProviderRegistry()

    private var factories: [String: (CloudProviderConfig) -> CloudProvider] = [:]

    func register(type: String, factory: @escaping (CloudProviderConfig) -> CloudProvider) {
        factories[type] = factory
    }

    func makeProvider(for config: CloudProviderConfig) -> CloudProvider? {
        factories[config.type]?(config)
    }

    var registeredTypes: [String] { Array(factories.keys) }
}
