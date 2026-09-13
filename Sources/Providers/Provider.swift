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

protocol CloudProvider: Sendable {
    var type: String { get }
    func listFiles(inFolder folderID: String?) async throws -> [CloudFile]
    func metadata(forFileID fileID: String) async throws -> CloudFile
    func streamURL(forFileID fileID: String) async throws -> URL
    func testConnection() async -> ConnectionTestResult
}

final class CloudProviderRegistry: @unchecked Sendable {
    static let shared = CloudProviderRegistry()

    private let lock = NSLock()
    private var factories: [String: (CloudProviderConfig) throws -> CloudProvider] = [:]

    func register(type: String, factory: @escaping (CloudProviderConfig) throws -> CloudProvider) {
        lock.withLock { factories[type] = factory }
    }

    func makeProvider(for config: CloudProviderConfig) throws -> CloudProvider? {
        let factory = lock.withLock { factories[config.type] }
        return try factory?(config)
    }

    var registeredTypes: [String] { lock.withLock { Array(factories.keys) } }
}
