import AppKit

final class StatusItemController {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Matches the switcher's row sizing closely enough to feel like the same UI, without
    // being as wide as a full Option-Tab panel — this is a dropdown menu, not an overlay.
    private static let rowMinHeight: CGFloat = 36
    private static let rowWidth: CGFloat = 300

    // Retained so the API-key menu items can trigger a full re-render (their title/presence
    // depends on whether a key is currently stored) without AppDelegate having to re-supply
    // the last context list just to refresh the Keychain-related rows.
    private var lastContexts: [Context] = []

    /// Set by AppDelegate to activate a context when its dropdown row is clicked — mirrors
    /// what the Option-Tab release handler does (ContextActivator.activate + markActivated),
    /// so clicking a row in the menu jumps to it exactly like selecting it in the overlay does.
    var onSelectContext: ((Context) -> Void)?

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

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let hasStoredKey = APIKeyStore.load() != nil
        let apiKeyItem = NSMenuItem(
            title: hasStoredKey ? "Anthropic API Key: Set ✓" : "Set Anthropic API Key…",
            action: #selector(setAPIKey), keyEquivalent: ""
        )
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        if hasStoredKey {
            let clearItem = NSMenuItem(title: "Clear Anthropic API Key", action: #selector(clearAPIKey), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(NSMenuItem(title: "Quit Roundabout", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
        // Re-read status rather than assuming success (e.g. requiresApproval, or a failure).
        menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin) })?.state =
            LoginItemManager.isEnabled ? .on : .off
    }

    // Stored in the Keychain (see APIKeyStore) rather than relying on the process
    // environment — a login-item launch has no shell and never sees ANTHROPIC_API_KEY set
    // that way, which otherwise leaves summarization silently disabled with no indication why.
    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Used for LLM-generated context summaries. Stored in the macOS Keychain, so it's available no matter how Roundabout is launched."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sk-ant-..."
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if APIKeyStore.save(key) {
            Log.write("Anthropic API key saved to Keychain.\n")
        } else {
            Log.write("Failed to save Anthropic API key to Keychain — see preceding error.\n")
        }
        render(contexts: lastContexts)
    }

    @objc private func clearAPIKey() {
        APIKeyStore.clear()
        Log.write("Anthropic API key cleared from Keychain.\n")
        render(contexts: lastContexts)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
