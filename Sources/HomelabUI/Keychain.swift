import Foundation
import HomelabKit
import Security

/// Tokens in the iOS Keychain: one generic-password item per server, readable after the first unlock (background
/// refresh), never synced to iCloud, never in a backup restored to another device.
public struct KeychainTokenStore: TokenStore {
    let service: String

    public init(service: String = "com.qantrex.homelab.token") {
        self.service = service
    }

    public func token(for server: UUID) -> String? {
        var query = base(server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for server: UUID) throws {
        SecItemDelete(base(server) as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var item = base(server)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func base(_ server: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain error \(status)." }
}
