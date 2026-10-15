import Foundation
import Security

/// Secure storage dedicated to the Valyu credential. The value is never surfaced to UI text.
public enum ValyuKeychainStore {
    private static let service = "org.danswriter.valyu"
    private static let account = "valyu"

    public static func set(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ValyuResearchError.invalidCredential
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ValyuResearchError.keychain }
        } else if status != errSecSuccess {
            throw ValyuResearchError.keychain
        }
    }

    public static func get() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw ValyuResearchError.keychain }
        return value
    }

    public static func delete() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ValyuResearchError.keychain }
    }

    /// Checks only item metadata so opening Research settings never reads a key.
    public static func hasKey() throws -> Bool {
        let query = keyPresenceQuery()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try keyPresenceResult(for: status)
    }

    static func keyPresenceQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecReturnAttributes as String: true,
         kSecMatchLimit as String: kSecMatchLimitOne,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    static func keyPresenceResult(for status: OSStatus) throws -> Bool {
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed { throw ValyuResearchError.keychain }
        throw ValyuResearchError.keychain
    }
}
