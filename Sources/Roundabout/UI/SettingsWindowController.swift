import AppKit

/// Roundabout's first real preferences window — everything else lives in the status-bar
/// menu, but a per-app on/off list is exactly the kind of feature that outgrows a menu (see
/// CLAUDE.md's note on Apple's HIG guidance for when to graduate from menu items to a
/// Settings window: a list whose length depends on how many apps you run doesn't fit a
/// fixed-size dropdown well).
///
/// Lists currently-running regular apps (not a historical "every app you've ever used" list)
/// — Roundabout only ever stores an app's display *name* in its snapshot history, not its
/// bundle identifier, so a not-currently-running app has no reliable way to resolve the
/// bundle identifier AppSummarizationPreferenceStore keys on. Simplicity here (only apps
/// currently running when you open Settings) beats a fragile name-based lookup for
/// historical entries.
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Roundabout Settings"
        window.center()
        window.isReleasedWhenClosed = false // AppDelegate retains this controller across show/hide, not just first open
        self.init(window: window)
        buildContent()
    }

    /// Rebuilds the app list from scratch — called each time the window is shown, since the
    /// set of running apps (and thus what's eligible to configure) can change between opens.
    func refresh() {
        buildContent()
    }

    private func buildContent() {
        guard let window else { return }

        let headerLabel = NSTextField(wrappingLabelWithString:
            "Roundabout can read on-screen text from other apps (via Accessibility) to generate a one-line AI summary of what you're doing there. A few sensitive categories are off by default — toggle any app below to change it.")
        headerLabel.font = .systemFont(ofSize: 12)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.preferredMaxLayoutWidth = 380

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let apps = Self.eligibleApps()
        if apps.isEmpty {
            let empty = NSTextField(labelWithString: "No other apps running right now.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(empty)
        } else {
            for app in apps {
                guard let bundleIdentifier = app.bundleIdentifier else { continue }
                listStack.addArrangedSubview(makeRow(app: app, bundleIdentifier: bundleIdentifier))
            }
        }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // documentView must be wrapped so the stack's width tracks the scroll view's clip
        // view rather than shrinking to its content's minimal width.
        let clipContainer = NSView()
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: clipContainer.bottomAnchor),
        ])
        scrollView.documentView = clipContainer

        let contentStack = NSStackView(views: [headerLabel, scrollView])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            headerLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            clipContainer.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        window.contentView = contentView
    }

    /// Regular-policy running apps, excluding Terminal/Safari (already handled by their own
    /// dedicated collectors/gates, not this preference store) and Roundabout itself.
    private static func eligibleApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let name = app.localizedName else { return false }
                return !FrontmostAppCollector.isCoveredByDedicatedCollector(name)
            }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func makeRow(app: NSRunningApplication, bundleIdentifier: String) -> NSView {
        let icon = NSImageView(image: app.icon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let nameField = NSTextField(labelWithString: app.localizedName ?? bundleIdentifier)
        nameField.font = .systemFont(ofSize: 13)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let toggle = NSSwitch()
        toggle.state = AppSummarizationPreferenceStore.isEnabled(bundleIdentifier: bundleIdentifier) ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        // Piggybacking the bundle identifier on the control's identifier is simpler than a
        // side-table keyed by ObjectIdentifier, and NSUserInterfaceItemIdentifier is just a
        // string wrapper, so any bundle ID is a valid value here.
        toggle.identifier = NSUserInterfaceItemIdentifier(bundleIdentifier)

        let row = NSStackView(views: [icon, nameField, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 380).isActive = true
        return row
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        guard let bundleIdentifier = sender.identifier?.rawValue else { return }
        AppSummarizationPreferenceStore.setEnabled(sender.state == .on, forBundleIdentifier: bundleIdentifier)
    }
}
