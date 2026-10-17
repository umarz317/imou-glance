import Foundation
import Security

/// Opt-in sign-in details, kept only in the login Keychain. Camera keys and session tokens are never saved.
struct SavedCredentials: Codable, Equatable {
    var account: String
    var password: String
    var areaCode: String

    static let service = "local.imou.peek.account"

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "default"]
    }

    static func load(service: String = service) -> SavedCredentials? {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedCredentials.self, from: data)
    }

    func save(service: String = Self.service) throws {
        let data = try JSONEncoder().encode(self)
        let query = Self.query(service: service)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrLabel as String] = "Imou Glance"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ImouError.message("Could not save sign-in to the Keychain.") }
    }

    static func delete(service: String = service) {
        SecItemDelete(query(service: service) as CFDictionary)
    }
}
