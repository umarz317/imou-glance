import Foundation
import Security

/// A Codable record kept as one generic password in the login Keychain, readable on this Mac only.
protocol KeychainRecord: Codable {
    static var service: String { get }
}

extension KeychainRecord {
    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "default"]
    }

    static func load(service: String = service) -> Self? {
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
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

/// Opt-in password sign-in details. Camera keys are never saved.
struct SavedCredentials: KeychainRecord, Equatable {
    var account: String
    var password: String
    var areaCode: String

    static let service = "local.imou.peek.account"
}

/// Opt-in Imou session from a QR sign-in, which has no password to save. Imou can revoke it at any time;
/// a rejected session is deleted and the user signs in again.
struct SavedSession: KeychainRecord, Equatable {
    var username: String
    var token: String
    var sessionId: String
    var host: String

    static let service = "local.imou.peek.session"
}
