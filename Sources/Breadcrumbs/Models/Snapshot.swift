import AppKit

struct Snapshot {
    let source: String       // "frontmost" | "terminal" | "safari"
    let app: String?
    let title: String?
    let cwd: String?
    let tty: String?
    let timestamp: Date
    var isFrontmostTab: Bool = false // for terminal/browser snapshots: is this tab selected in its window?
    var processName: String? = nil   // foreground process in a terminal tab, e.g. "zsh" or "claude"
    var url: String? = nil           // page URL, for browser tabs
    var isActiveNow: Bool = false    // was this genuinely the thing in focus at collection time (not just open)?
}

struct Context: Identifiable {
    let id: String            // stable clustering key: "cwd::processName", "url", or "app:<name>" fallback
    let cwd: String?          // the actual filesystem path, for transcript lookup / activation — nil for non-terminal contexts
    var label: String         // directory name / page title / app name, cheap default
    var summary: String?      // LLM-generated one-liner, filled in async
    var lastSeen: Date
    var sources: Set<String>
    var app: String           // app to activate when jumping here (e.g. "Terminal", "Safari")
    var tty: String?          // specific terminal tab to focus, if this context is terminal-backed
    var processName: String?  // foreground process, if this context is terminal-backed — gates transcript summarization
    var url: String?          // specific browser tab to focus, if this context is browser-backed

    /// A stable accent color derived from the context's id, so a given cwd/app
    /// keeps the same color across launches rather than being reassigned each time.
    var accentColor: NSColor {
        var hasher = Hasher()
        hasher.combine(id)
        let hash = hasher.finalize()
        let hue = CGFloat(abs(hash) % 360) / 360.0
        return NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.9, alpha: 1.0)
    }
}
