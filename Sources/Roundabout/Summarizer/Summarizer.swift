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

    /// Summarizes a browser tab from its visible page text. Used only when a tab's title
    /// collides with another open tab's (e.g. several generic same-named app tabs), since
    /// that's the case where the title alone can't tell them apart.
    func summarizeWebPage(title: String, excerpt: String) async -> SummarizerResult?
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

        This tab's title is shared by other open tabs, so give it a short, distinct name and a
        one-sentence summary of what's specifically happening on this page — something that would
        help someone tell it apart from the other same-titled tabs.
        """
    }
}
