import Foundation
import Security

/// API key storage. Keychain first; falls back to `~/.kenari/credentials.json`
/// (`{"api_key": "kn-..."}`, also accepts `{"KENARI_API_KEY": "..."}`) so CLI users need no setup.
///
/// Two slots exist because Kenari issues two kinds of key:
///   • the tool key (`kenari-api-key`) — restricted; can read `/v1/usage` only.
///   • the account key (`kenari-account-key`) — from `kenari login`; can read
///     `/v1/account/quota` and `/v1/account/balance`.
/// Usage works with either; quota and balance need the account key.
public enum KeyStore {
    public static let service = "com.usagebar.app"
    public static let account = "kenari-api-key"
    public static let accountSlot = "kenari-account-key"

    public static var credentialsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kenari/credentials.json")
    }

    /// Restricted tool key: used for `/v1/usage`.
    public static func key() -> String? {
        if let k = ProcessInfo.processInfo.environment["KENARI_API_KEY"], !k.isEmpty { return k }
        if let k = keychainRead(account: account), !k.isEmpty { return k }
        return fileKey()
    }

    /// Account-wide key: used for quota and balance. Falls back to the tool key, which then
    /// simply 403s — the UI shows the quota block as unavailable rather than failing.
    public static func accountKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["KENARI_ACCOUNT_API_KEY"], !k.isEmpty { return k }
        if let k = keychainRead(account: accountSlot), !k.isEmpty { return k }
        if let obj = fileObject() {
            for k in ["account_api_key", "KENARI_ACCOUNT_API_KEY"] {
                if let v = obj[k] as? String, !v.isEmpty { return v }
            }
        }
        return key()
    }

    public static func setKey(_ key: String) throws { try write(key, account: account) }
    public static func setAccountKey(_ key: String) throws { try write(key, account: accountSlot) }

    public static func clearKey() {
        for slot in [account, accountSlot] { keychainDelete(account: slot) }
    }

    public static var hasKey: Bool { key() != nil }

    // MARK: - Keychain

    static func baseQuery(account slot: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: slot]
    }

    static func write(_ key: String, account slot: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyStoreError.empty }
        let query = baseQuery(account: slot)
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(trimmed.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    static func keychainDelete(account slot: String) {
        SecItemDelete(baseQuery(account: slot) as CFDictionary)
    }

    static func keychainRead(account slot: String) -> String? {
        var query = baseQuery(account: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - File fallback

    static func fileObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: credentialsFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func fileKey() -> String? {
        guard let obj = fileObject() else { return nil }
        for k in ["api_key", "KENARI_API_KEY", "kenari_api_key", "apiKey"] {
            if let v = obj[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }
}

public enum KeyStoreError: LocalizedError {
    case empty
    case keychain(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .empty: return "API key is empty"
        case .keychain(let s): return "Keychain error \(s)"
        }
    }
}
