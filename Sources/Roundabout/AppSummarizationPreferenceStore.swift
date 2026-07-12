import Foundation

/// Persists per-app opt-out of general (Accessibility-based) app summarization, keyed by
/// bundle identifier — not app name, since names aren't guaranteed unique/stable the way a
/// bundle ID is. Plain UserDefaults (see SummarizerPreferenceStore for the same reasoning):
/// these are preferences, not secrets.
///
/// Distinct from Safari/Terminal summarization, which are separately gated and unaffected by
/// this store — this only governs the generic "read whatever app is currently active via
/// Accessibility" path (see AppDelegate's third summarization branch).
enum AppSummarizationPreferenceStore {
    private static let overridesKey = "appSummarizationOverrides"

    /// Well-known bundle identifiers excluded from summarization out of the box — password/
    /// credential managers (their whole UI is sensitive by definition) plus Messages and Mail
    /// (personal correspondence, not credential-shaped but still not something that should be
    /// read and sent to a summarizer without an explicit opt-in). This list is deliberately
    /// small and only covers the obvious/common cases — anyone can add further exclusions (or
    /// remove these two apps from exclusion) via the Settings window; nothing here is meant to
    /// be an exhaustive or authoritative registry.
    static let defaultBlacklist: Set<String> = [
        "com.apple.MobileSMS",              // Messages
        "com.apple.mail",                   // Mail
        "com.apple.keychainaccess",         // Keychain Access
        "com.1password.1password",          // 1Password 8
        "com.agilebits.onepassword7",       // 1Password 7
        "com.bitwarden.desktop",            // Bitwarden
        "com.lastpass.LastPass",            // LastPass
        "com.dashlane.dashlanephonefinal",  // Dashlane
        "com.markmcguill.Keeper",           // Keeper
        "com.strongboxsafe.strongbox",      // Strongbox
        "com.enpass.Enpass",                // Enpass
        "com.nordpass.NordPass",            // NordPass
    ]

    /// Explicit per-bundle-identifier overrides the user has set via the Settings window —
    /// true/false meaning "explicitly enabled"/"explicitly disabled", overriding whatever
    /// defaultBlacklist would otherwise say. Absence of a key means "use the default."
    private static var overrides: [String: Bool] {
        get {
            (UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: Bool]) ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: overridesKey)
        }
    }

    static func isEnabled(bundleIdentifier: String) -> Bool {
        if let override = overrides[bundleIdentifier] {
            return override
        }
        return !defaultBlacklist.contains(bundleIdentifier)
    }

    static func setEnabled(_ enabled: Bool, forBundleIdentifier bundleIdentifier: String) {
        var current = overrides
        current[bundleIdentifier] = enabled
        overrides = current
    }
}
