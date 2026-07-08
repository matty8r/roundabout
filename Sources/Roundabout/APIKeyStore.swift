import Security
import Foundation

/// Persists the Anthropic API key in the macOS Keychain so it's available regardless of
/// how Roundabout was launched. Reading `ANTHROPIC_API_KEY` from the process environment
/// (the original approach) only works for the dev-loop run, where the process is launched
/// from a shell with `.env` sourced — a login-item launch is started directly by `launchd`
/// with no shell involved, so that environment variable is never set, and summarization
/// silently and permanently falls back to cheap labels with no indication why. The Keychain
/// is readable regardless of launch path, so this is what makes summarization actually work
/// in the app's primary running mode (see CLAUDE.md: "runs continuously in the background").
enum APIKeyStore {
    private static let service = "com.msilas.roundabout"
    // The service identifier used before the app was renamed from Breadcrumbs. Checked as a
    // fallback purely so a key saved before the rename isn't silently orphaned — without
    // this, renaming the app would look to the user like their previously-working key just
    // stopped working, for no visible reason.
    private static let legacyService = "com.msilas.breadcrumbs"
    private static let account = "ANTHROPIC_API_KEY"

    static func load() -> String? {
        if let key = load(service: service) {
            return key
        }
        guard let legacyKey = load(service: legacyService) else { return nil }
        // One-time migration: move the entry to the current service name so Keychain
        // Access reflects the app's current identity instead of straddling both names
        // indefinitely. Idempotent — once this succeeds, the next load() finds the key
        // under `service` directly and never reaches this path again.
        if save(legacyKey) {
            _ = clear(service: legacyService)
            Log.write("Migrated Anthropic API key in Keychain from '\(legacyService)' to '\(service)'.\n")
        } else {
            Log.write("Found Anthropic API key under legacy Keychain service '\(legacyService)' but failed to migrate it to '\(service)' — leaving the legacy entry in place.\n")
        }
        return legacyKey
    }

    private static func load(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Update in place if a key already exists; otherwise add a new item.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Readable as soon as the keychain is unlocked once after boot — needed since a
            // login-item launch can happen before the user has interactively unlocked, and
            // waiting for kSecAttrAccessibleWhenUnlocked would fail in that window.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.write("Failed to save API key to Keychain (status \(addStatus)).\n")
            }
            return addStatus == errSecSuccess
        }
        if updateStatus != errSecSuccess {
            Log.write("Failed to update API key in Keychain (status \(updateStatus)).\n")
        }
        return updateStatus == errSecSuccess
    }

    @discardableResult
    static func clear() -> Bool {
        clear(service: service)
    }

    @discardableResult
    private static func clear(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
