import Foundation
import Security

enum KeychainStore {
    private static let service = "com.relaypulse.app.credentials"

    static func save(_ credentials: StationSecretCredentials, for stationID: UUID) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let account = accountKey(for: stationID)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load(for stationID: UUID) -> StationSecretCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(for: stationID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode(StationSecretCredentials.self, from: data) else {
            return StationSecretCredentials()
        }
        return decoded
    }

    static func delete(for stationID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(for: stationID)
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func accountKey(for stationID: UUID) -> String {
        "station.\(stationID.uuidString)"
    }
}
