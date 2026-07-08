import Foundation

enum SummarizerProvider: String {
    case onDevice
    case anthropic
}

/// Persists which summarization backend the user has chosen via the status-bar menu's
/// "Summarization" submenu. Defaults to on-device (FoundationModels) — free, private, no API
/// key required — with Anthropic Claude available as an explicit opt-in. Plain UserDefaults
/// rather than Keychain (see APIKeyStore): this is a preference, not a secret.
enum SummarizerPreferenceStore {
    private static let key = "summarizerProvider"

    static var current: SummarizerProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key), let value = SummarizerProvider(rawValue: raw) else {
                return .onDevice
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
