import AppKit

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Matches the switcher's row sizing closely enough to feel like the same UI, without
    // being as wide as a full Option-Tab panel — this is a dropdown menu, not an overlay.
    private static let rowMinHeight: CGFloat = 36
    private static let rowWidth: CGFloat = 300

    private var lastContexts: [Context] = []

    /// Set by AppDelegate to activate a context when its dropdown row is clicked — mirrors
    /// what the Option-Tab release handler does (ContextActivator.activate + markActivated),
    /// so clicking a row in the menu jumps to it exactly like selecting it in the overlay does.
    var onSelectContext: ((Context) -> Void)?

    /// Set by AppDelegate to show (creating on first use) the Settings window — Launch at
    /// Login, Summarization provider/API key, and per-app summarization all live there now
    /// rather than in this menu (see SettingsWindowController).
    var onOpenSettings: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = Self.loadMenuBarIcon() {
            statusItem.button?.image = icon
        } else {
            // Only reachable if AppIcon.svg didn't make it into the bundle (e.g. running the
            // raw .build binary directly instead of the assembled .app) — fall back to
            // *something* recognizable rather than an empty status item.
            statusItem.button?.title = "🔄"
        }
        statusItem.menu = menu
        render(contexts: [])
    }

    /// Loads MenuBarIcon.svg (the roundabout sign's three arrows, cropped from AppIcon.svg
    /// with the blue disc dropped — see scripts/build_app.sh) as a *template* image, so
    /// AppKit recolors it to match the system's other menu bar items (light/dark menu bar,
    /// vibrancy, selection highlighting) instead of rendering fixed colors that would look
    /// out of place next to native status items.
    private static func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    func render(contexts: [Context]) {
        lastContexts = contexts
        menu.removeAllItems()

        if contexts.isEmpty {
            let item = NSMenuItem(title: "No contexts yet…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for context in contexts {
                // A custom view replaces NSMenuItem's default single-line title rendering,
                // which is what forced everything onto one truncated line and grayed the
                // text out. ContextRowView draws its own colors and wraps the summary across
                // multiple lines instead of truncating, regardless of the item's enabled state.
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                // Enabled so the row can hover-highlight and receive the click — ContextRowView
                // does its own click handling via onSelect (below) rather than NSMenuItem's
                // normal target/action dispatch, which custom-view items don't participate in.
                item.isEnabled = true
                let row = ContextRowView(context: context, minHeight: Self.rowMinHeight, width: Self.rowWidth)
                // NSMenu reads a custom item view's *frame* synchronously when it's assigned,
                // to reserve that item's row height/hit-test region — it does not wait for a
                // later Auto Layout pass the way normal window content would. ContextRowView
                // is built with translatesAutoresizingMaskIntoConstraints = false and no frame
                // ever set, so without this it stays .zero at assignment time: the menu still
                // *renders* each row correctly (drawing happens after layout resolves), but the
                // click/hit-test regions for every item are computed from the stale zero-sized
                // geometry — which is why rows after these looked fine but weren't clickable.
                row.layoutSubtreeIfNeeded()
                row.frame = NSRect(origin: .zero, size: row.fittingSize)
                row.onSelect = { [weak self] in self?.onSelectContext?(context) }
                item.view = row
                item.toolTip = context.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let helpItem = NSMenuItem(title: "How to Use Roundabout", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem(title: "Quit Roundabout", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    /// (heading, body) pairs for the help panel below. Plain NSAlert.informativeText is a
    /// single unstyled String — no bold runs — so headers are built as their own bold
    /// NSTextField instead, matching the title/summary text style ContextRowView already
    /// uses elsewhere, and handed to the alert via accessoryView rather than informativeText.
    private static let helpSections: [(heading: String, body: String)] = [
        ("Option-Tab", "Hold Option, tap Tab to cycle contexts, release to jump — like Cmd-Tab, per tab."),
        ("This menu", "Click any context above to jump straight to it."),
        ("Settings", "Summarization provider, Launch at Login, and per-app permissions all live in Settings… (⌘,)."),
        ("Permissions", "Accessibility (for Option-Tab) and Automation for Terminal/Safari, requested on first use."),
    ]

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Roundabout"
        alert.informativeText = "Jumps you back to your actual working context — not just an app, but the exact Terminal tab, Safari tab, or window — with one gesture."

        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true

        for section in Self.helpSections {
            let heading = NSTextField(labelWithString: section.heading)
            heading.font = .boldSystemFont(ofSize: 12)

            let body = NSTextField(wrappingLabelWithString: section.body)
            body.font = .systemFont(ofSize: 12)
            body.textColor = .secondaryLabelColor
            body.preferredMaxLayoutWidth = width

            let sectionStack = NSStackView(views: [heading, body])
            sectionStack.orientation = .vertical
            sectionStack.alignment = .leading
            sectionStack.spacing = 2
            stack.addArrangedSubview(sectionStack)
        }

        // NSAlert reads a custom accessoryView's *frame* synchronously when it's assigned,
        // the same way NSMenu does for a custom NSMenuItem.view (see the context-row fix
        // above) — it doesn't wait for a later Auto Layout pass. Skipping this leaves the
        // stack at its initial .zero frame, and the alert's window ends up sized for that,
        // so the accessory content overlaps the messageText/informativeText above it instead
        // of appearing in its own space below them.
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
