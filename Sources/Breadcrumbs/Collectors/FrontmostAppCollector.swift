import AppKit
import Foundation

enum FrontmostAppCollector {
    static func collect() -> Snapshot? {
        // .regular excludes system/background agents (loginwindow, UserNotificationCenter,
        // universalAccessAuthWarn — the last of which pops up when Breadcrumbs itself
        // requests Accessibility permission) that can briefly become "frontmost" without
        // being anything the user would recognize as a context they were working in.
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular else { return nil }
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
