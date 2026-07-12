import Foundation

/// Common interface so AppDelegate can call whichever backend the user has selected (see
/// SummarizerPreferenceStore) without caring which one it is. Both entry points return nil
/// (caller keeps the cheap default label) when there's nothing to summarize from, or the
/// backend is unavailable/unconfigured — never throws, since a summary is always optional
/// enhancement, not something the rest of the app depends on.
protocol Summarizer {
    /// Summarizes a working context using recent Claude Code transcript text, if any exists
    /// for this cwd.
    func summarize(cwd: String, label: String) async -> SummarizerResult?

    /// Summarizes a browser tab from its visible page text.
    func summarizeWebPage(title: String, excerpt: String) async -> SummarizerResult?

    /// Summarizes visible on-screen text from an arbitrary app (see AccessibilityTextReader),
    /// for apps with no dedicated collector (i.e. anything other than Terminal/Safari).
    func summarizeAppContent(appName: String, excerpt: String) async -> SummarizerResult?
}

struct SummarizerResult {
    let name: String
    let summary: String
}

/// Prompt text shared by every backend, so switching providers (see the status-bar menu's
/// "Summarization" submenu) doesn't also silently change what's being asked for.
enum SummarizerPrompts {
    static func terminal(label: String, excerpt: String) -> String {
        """
        Here is a recent excerpt from a coding session in directory "\(label)":

        \(excerpt)

        Give this working context a short human-readable name and a one-sentence summary of what's currently being worked on.
        """
    }

    static func webPage(title: String, excerpt: String) -> String {
        """
        Here is the title and visible text content of a browser tab titled "\(title)":

        \(excerpt)

        Give this working context a short human-readable name and a one-sentence summary of what's currently being worked on.
        """
    }

    static func appContent(appName: String, excerpt: String) -> String {
        """
        Here is visible on-screen text from an app called "\(appName)":

        \(excerpt)

        Give this working context a short human-readable name and a one-sentence summary of what's currently being worked on. If the text is mostly UI chrome (menus, toolbars, button labels) with little real content, say so briefly rather than guessing.
        """
    }
}
