import Foundation
import Security

protocol APIKeyStoring: Sendable {
    func hasKey(for provider: AIProvider) -> Bool
    func key(for provider: AIProvider) throws -> String?
    func save(_ key: String, for provider: AIProvider) throws
    func delete(for provider: AIProvider) throws
}

struct APIKeyStoreError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain couldn't store this key: \(detail)"
    }
}

/// API keys, kept only in the login Keychain: never in preferences, logs or reports.
struct KeychainAPIKeyStore: APIKeyStoring {
    var servicePrefix = "com.provenancecleaner.mac.ai"

    private func query(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(servicePrefix).\(provider.rawValue)",
            kSecAttrAccount as String: "api-key",
        ]
    }

    func hasKey(for provider: AIProvider) -> Bool {
        SecItemCopyMatching(query(for: provider) as CFDictionary, nil) == errSecSuccess
    }

    func key(for provider: AIProvider) throws -> String? {
        var request = query(for: provider)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStoreError(status: status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(_ key: String, for provider: AIProvider) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(for: provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIKeyStoreError(status: status) }
        var item = query(for: provider)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Provenance Cleaner: \(provider.displayName) API key"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw APIKeyStoreError(status: added) }
    }

    func delete(for provider: AIProvider) throws {
        let status = SecItemDelete(query(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyStoreError(status: status) }
    }
}
