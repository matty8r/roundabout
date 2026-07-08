import AppKit
import Foundation

enum FrontmostAppCollector {
    /// Terminal and Safari already have dedicated collectors that produce tab-specific
    /// contexts (keyed by cwd::process or url). Without this exclusion, this collector
    /// would *also* emit an "app:Terminal"/"app:Safari" fallback snapshot every time either
    /// is frontmost — a second, less useful context (no cwd/tty, so activating it can only
    /// generically foreground the app) competing for a switcher slot alongside the real one.
    /// Trade-off: a glance at Terminal/Safari shorter than one 15s poll interval won't get
    /// an instant isActiveNow bump the way other apps do via the event-driven path — but
    /// TerminalCollector/SafariCollector's own poll picks up the actual tab within 15s anyway.
    private static let appsCoveredByDedicatedCollector: Set<String> = ["Terminal", "Safari"]

    static func isCoveredByDedicatedCollector(_ appName: String) -> Bool {
        appsCoveredByDedicatedCollector.contains(appName)
    }

    static func collect() -> Snapshot? {
        // .regular excludes system/background agents (loginwindow, UserNotificationCenter,
        // universalAccessAuthWarn — the last of which pops up when Roundabout itself
        // requests Accessibility permission) that can briefly become "frontmost" without
        // being anything the user would recognize as a context they were working in.
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              !(app.localizedName.map(isCoveredByDedicatedCollector) ?? false) else { return nil }
        return Snapshot(
            source: "frontmost",
            app: app.localizedName,
            title: nil,
            cwd: nil,
            tty: nil,
            timestamp: Date(),
            isActiveNow: true // by construction: this collector only ever reports the current frontmost app
        )
    }
}
