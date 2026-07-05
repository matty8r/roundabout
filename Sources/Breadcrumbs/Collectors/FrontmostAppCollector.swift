import AppKit
import Foundation

enum FrontmostAppCollector {
    static func collect() -> Snapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
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
