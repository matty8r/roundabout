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
        menu.addItem(NSMenuItem(title: "Quit Breadcrumbs", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
