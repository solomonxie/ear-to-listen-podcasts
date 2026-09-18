import Foundation
import Security

enum CredentialStoreError: Error {
    case unhandled(OSStatus)
}

struct CredentialStore {
    private let service = "com.solomonxie.eartolisten"

    func set(_ value: String, forKey key: String) throws {
        try delete(key)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        attributes[kSecValueData as String] = Data(value.utf8)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CredentialStoreError.unhandled(status) }
    }

    func get(_ key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unhandled(status)
        }
    }

    func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unhandled(status)
        }
    }

    func setJSON<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        try set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    func getJSON<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let raw = try get(key) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }
}
