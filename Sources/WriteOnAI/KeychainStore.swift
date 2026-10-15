import Foundation
import Security

public enum KeychainStore {
    private static let service = "org.danswriter.credentials"

    public static func set(_ value: String, for provider: AIProvider) throws {
        let account = provider.rawValue
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AIError.keychain("Save failed (\(addStatus)).") }
        } else if status != errSecSuccess {
            throw AIError.keychain("Save failed (\(status)).")
        }
    }

    public static func get(for provider: AIProvider) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AIError.keychain("Read failed (\(status)).")
        }
        return value
    }

    /// Checks for a saved credential using Keychain attributes only. This is
    /// suitable for rendering UI status and never returns the credential data.
    public static func hasKey(for provider: AIProvider) throws -> Bool {
        let query = keyPresenceQuery(for: provider)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return try keyPresenceResult(for: status)
    }

    static func keyPresenceQuery(for provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue,
         kSecReturnAttributes as String: true,
         kSecMatchLimit as String: kSecMatchLimitOne,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    static func keyPresenceResult(for status: OSStatus) throws -> Bool {
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        if status == errSecInteractionNotAllowed {
            throw AIError.keychain("Status unavailable (\(status)).")
        }
        throw AIError.keychain("Status unavailable (\(status)).")
    }

    public static func delete(for provider: AIProvider) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: provider.rawValue]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIError.keychain("Delete failed (\(status)).")
        }
    }
}
