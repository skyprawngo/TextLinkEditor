import Foundation
import Security

/// Installation-scoped identity, not a hardware fingerprint. Never synced through iCloud.
enum UpdateIdentity {
    private static let service = "com.textlinkeditor.app.updates"

    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw IdentityError.keychain }
        return value
    }

    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw IdentityError.keychain }
    }

    static func deviceID() throws -> String {
        if let existing = try read("device-id") { return existing }
        let identifier = UUID().uuidString.lowercased()
        try write(identifier, account: "device-id")
        return identifier
    }

    enum IdentityError: LocalizedError {
        case keychain
        var errorDescription: String? { L10n.get("updates.keychainError") }
    }
}
