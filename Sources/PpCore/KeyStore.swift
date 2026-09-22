import Foundation
import Security

/// Keychain-backed store for API credentials.
public enum KeyStore {
    public static let decision = "decision-api-key"
    public static let customPlanner = "custom-planner-api-key"
    public static let planner = "custom-planner-api-key"

    public struct KeyError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.pp",
         kSecAttrAccount as String: account]
    }

    public static func read(_ account: String = decision) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw failure(status) }
        return key
    }

    public static func save(_ key: String, account: String = decision) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyError(message: "Enter an API key.") }
        let attributes = [kSecValueData as String: Data(trimmed.utf8)]
        let result = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if result != errSecSuccess { throw failure(result) }
    }

    public static func delete(_ account: String = decision) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw failure(status)
        }
    }

    private static func failure(_ status: OSStatus) -> KeyError {
        KeyError(message: "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")")
    }
}
