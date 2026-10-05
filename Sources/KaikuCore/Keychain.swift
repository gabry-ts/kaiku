import Foundation
import Security

/// Minimal Keychain wrapper for API keys (generic passwords).
public enum Keychain {
    private static let service = "com.gabrielepartiti.kaiku"
    /// Service name used before the app was renamed.
    public static let legacyService = "com.gabrielepartiti.mcrofone"

    /// When set, used instead of the real Keychain (snapshot rendering).
    public static var mock: [String: String]?

    /// Keychain failures other than "not found", by account, shown instead of "missing key".
    public private(set) static var errors: [String: String] = [:]

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    public static func get(_ account: String) -> String? {
        if let mock { return mock[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess || status == errSecItemNotFound { errors[account] = nil }
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecSuccess && status != errSecItemNotFound {
                // e.g. a locked keychain: not the same as a key never entered.
                errors[account] = "Couldn't read \(account) from the Keychain: \(describe(status))"
                Log.app.error("Keychain read failed for \(account, privacy: .public): \(describe(status), privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value` (an empty one deletes the item). Updates in place, so a failure never
    /// loses the key saved before. Returns false when the Keychain refused.
    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        if mock != nil { mock?[account] = value; return true }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(base as CFDictionary)
            if status == errSecItemNotFound { status = errSecSuccess }
        } else {
            let data = Data(value.utf8)
            status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = base
                add[kSecValueData as String] = data
                #if os(iOS)
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                #endif
                status = SecItemAdd(add as CFDictionary, nil)
            }
        }
        guard status == errSecSuccess else {
            errors[account] = "Couldn't save \(account) in the Keychain: \(describe(status))"
            Log.app.error("Keychain write failed for \(account, privacy: .public): \(describe(status), privacy: .public)")
            return false
        }
        errors[account] = nil
        return true
    }

    /// Copies every generic password of `from` that `service` does not have yet, keeping
    /// the originals. Returns the number of items copied.
    public static func copyItems(from legacy: String) -> Int {
        let list: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(list as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return 0 }
        var copied = 0
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) where get(account) == nil {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacy,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty else { continue }
            set(value, for: account)
            copied += 1
        }
        return copied
    }
}
