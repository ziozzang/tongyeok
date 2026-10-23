import Foundation
import Security

/// API keys in the login Keychain instead of the preferences plist.
/// All keys live in ONE generic-password item (JSON), so an ad-hoc signed update -- which Keychain treats as a
/// new app -- asks for access once, not once per key.
enum SecretStore {
    static var service = "net.jioh.stttrans"   // var: tests use their own item
    static let account = "api-keys"
    /// Debug hook: never touch the Keychain (tests / automation, avoids access prompts).
    static let disabled = ProcessInfo.processInfo.environment["STTTRANS_NO_KEYCHAIN"] != nil

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Blocking (may show the Keychain access prompt): call off the main thread.
    static func load() -> [String: String] {
        guard !disabled else { return [:] }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            if status != errSecItemNotFound { dlog("keychain load failed: \(status)") }
            return [:]
        }
        return dict
    }

    @discardableResult
    static func save(_ secrets: [String: String]) -> Bool {
        guard !disabled else { return true }
        let nonEmpty = secrets.filter { !$0.value.isEmpty }
        if nonEmpty.isEmpty { return SecItemDelete(query as CFDictionary) == errSecSuccess }
        guard let data = try? JSONEncoder().encode(nonEmpty) else { return false }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Tongyeok API keys"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { dlog("keychain save failed: \(status)") }
        return status == errSecSuccess
    }
}
