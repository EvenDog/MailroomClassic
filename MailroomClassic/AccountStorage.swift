// Saves and loads account settings between launches. Server names and email
// addresses go in UserDefaults (the app's simple preferences storage);
// secrets (passwords, or the Microsoft sign-in token) go in the macOS
// Keychain, the system's encrypted password store.

import Foundation
import Security

enum AccountStorage {
    private static let accountsKey = "accounts"
    private static let keychainService = "com.evendog.MailroomClassic"

    // MARK: - Account settings (UserDefaults)

    // Returns the saved accounts, or an empty list if none were saved yet.
    static func loadAccounts() -> [AccountSettings] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        return (try? JSONDecoder().decode([AccountSettings].self, from: data)) ?? []
    }

    static func saveAccounts(_ accounts: [AccountSettings]) {
        let data = try? JSONEncoder().encode(accounts)
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    // MARK: - Secrets (Keychain)
    // The Keychain API is old C-style code: you describe the item you want
    // with a dictionary of `kSec...` keys, then call a SecItem function.

    static func saveSecret(_ secret: String, for accountID: UUID) throws {
        deleteSecret(for: accountID)   // replace any old one
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecValueData as String: Data(secret.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    // Returns the saved secret for an account, or throws if there isn't one.
    static func secret(for accountID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func deleteSecret(for accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Turns a Keychain status code into a readable error message.
struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return "Keychain error: \(message)"
    }
}
