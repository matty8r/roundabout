import AppKit

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🍞"
        statusItem.menu = menu
        render(contexts: [])
    }

    func render(contexts: [Context]) {
        menu.removeAllItems()

        if contexts.isEmpty {
            let item = NSMenuItem(title: "No contexts yet…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for context in contexts {
                let title = context.summary.map { "\(context.label) — \($0)" } ?? context.label
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.toolTip = context.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem(title: "Quit Breadcrumbs", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
        // Re-read status rather than assuming success (e.g. requiresApproval, or a failure).
        menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) })?.state =
            LoginItemManager.isEnabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
