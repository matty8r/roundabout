import AppKit

/// Roundabout's one preferences window — General, Summarization, and per-app summarization
/// access all live here now, instead of being spread across the status-bar menu (see
/// CLAUDE.md's note on Apple's HIG guidance for when to graduate from menu items to a real
/// Settings window: a per-app list whose length depends on how many apps you run, plus a
/// provider choice and an API key field, is well past that threshold).
final class SettingsWindowController: NSWindowController {
    private static let contentWidth: CGFloat = 420

    /// Set by AppDelegate to clear the summary cache and re-render immediately after the
    /// user switches providers, rather than leaving stale summaries from the old provider
    /// on screen until they age out of the cache.
    var onSummarizerPreferenceChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Roundabout Settings"
        window.minSize = NSSize(width: 460, height: 420)
        window.center()
        window.isReleasedWhenClosed = false // AppDelegate retains this controller across show/hide, not just first open
        self.init(window: window)
        buildContent()
    }

    /// Rebuilds the whole window content from scratch — called both when AppDelegate shows
    /// the window (the set of running apps can change between opens) and internally whenever
    /// a control changes something that affects what else should be visible (e.g. picking
    /// Anthropic reveals the API key row). Rebuilding is simpler and plenty fast for a
    /// preferences window with a few dozen rows at most — no need for incremental diffing.
    func refresh() {
        buildContent()
    }

    private func buildContent() {
        guard let window else { return }

        // Every section except the last resists stretching (.required vertical hugging) so
        // the extra space a taller/resized window creates all goes to the one section that
        // should actually use it — the app list. Without this, NSStackView's .fill
        // distribution has no basis to prefer one arranged subview over another and the
        // extra space either goes nowhere (bottomAnchor left as <=, the previous behavior:
        // the window just had dead space below a fixed-height list) or gets distributed
        // ambiguously across everything.
        let generalSection = makeGeneralSection()
        let summarizationSection = makeSummarizationSection()
        let appSummarizationSection = makeAppSummarizationSection()
        for section in [generalSection, summarizationSection] {
            section.setContentHuggingPriority(.required, for: .vertical)
        }

        let sections: [NSView] = [
            generalSection,
            Self.makeDivider(),
            summarizationSection,
            Self.makeDivider(),
            appSummarizationSection,
        ]

        let contentStack = NSStackView(views: sections)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // Equal, not <=: forces the stack to occupy the full content view height, which
            // is what gives the low-hugging-priority app list something to expand into.
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window.contentView = contentView
    }

    // MARK: - Section builders

    private static func makeSectionHeader(_ title: String, description: String? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: 13)

        guard let description else { return heading }
        let body = NSTextField(wrappingLabelWithString: description)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = contentWidth

        let stack = NSStackView(views: [heading, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private static func makeDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return box
    }

    /// A single-row preference: title/description on the left, an arbitrary trailing
    /// control on the right, pinned to the row's trailing edge regardless of title length —
    /// the label stack's low horizontal hugging priority is what lets it stretch to push the
    /// control over, rather than the control just sitting immediately after a short title.
    private static func makePreferenceRow(title: String, description: String? = nil, control: NSView) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13)

        var labelViews: [NSView] = [titleField]
        if let description {
            let body = NSTextField(wrappingLabelWithString: description)
            body.font = .systemFont(ofSize: 11)
            body.textColor = .secondaryLabelColor
            body.preferredMaxLayoutWidth = contentWidth - 100
            labelViews.append(body)
        }
        let labelStack = NSStackView(views: labelViews)
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelStack, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func makeGeneralSection() -> NSView {
        let loginToggle = NSSwitch()
        loginToggle.state = LoginItemManager.isEnabled ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(loginToggleChanged(_:))

        let row = Self.makePreferenceRow(
            title: "Launch at Login",
            description: "Start Roundabout automatically when you log in.",
            control: loginToggle
        )

        let stack = NSStackView(views: [Self.makeSectionHeader("General"), row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func makeSummarizationSection() -> NSView {
        let provider = SummarizerPreferenceStore.current

        let segmented = NSSegmentedControl(labels: ["On-Device", "Anthropic"], trackingMode: .selectOne, target: self, action: #selector(providerChanged(_:)))
        segmented.selectedSegment = provider == .onDevice ? 0 : 1

        let providerRow = Self.makePreferenceRow(
            title: "Summarize contexts using",
            description: "A one-line AI description of what's happening in each context.",
            control: segmented
        )

        var rows: [NSView] = [Self.makeSectionHeader("Summarization"), providerRow]

        if provider == .onDevice, let reason = FoundationModelsSummarizer.unavailableReason {
            let warning = NSTextField(wrappingLabelWithString: "⚠️ \(reason)")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = .secondaryLabelColor
            warning.preferredMaxLayoutWidth = Self.contentWidth
            rows.append(warning)
        }

        if provider == .anthropic {
            rows.append(makeAPIKeyRow())
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func makeAPIKeyRow() -> NSView {
        let hasStoredKey = APIKeyStore.load() != nil
        let button = NSButton(title: hasStoredKey ? "Clear Key" : "Set Key…", target: self, action: #selector(apiKeyButtonClicked))
        button.bezelStyle = .rounded
        return Self.makePreferenceRow(
            title: "Anthropic API Key",
            description: hasStoredKey ? "Set — stored in the macOS Keychain." : "Required for the Anthropic provider.",
            control: button
        )
    }

    private func makeAppSummarizationSection() -> NSView {
        let header = Self.makeSectionHeader(
            "App Summarization",
            description: "Roundabout can read on-screen text from other apps (via Accessibility) to summarize what you're doing there. A few sensitive categories are off by default."
        )

        let apps = Self.eligibleApps()
        let listView: NSView
        if apps.isEmpty {
            let empty = NSTextField(labelWithString: "No other apps running right now.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            listView = empty
        } else {
            let table = NSTableView()
            table.style = .inset
            table.rowHeight = 36
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let column = NSTableColumn(identifier: .init("app"))
            column.width = Self.contentWidth
            table.addTableColumn(column)

            let dataSource = AppListDataSource(apps: apps)
            table.dataSource = dataSource
            table.delegate = dataSource
            self.appListDataSource = dataSource // retained — NSTableView holds its data source/delegate weakly

            let scrollView = NSScrollView()
            scrollView.documentView = table
            scrollView.hasVerticalScroller = true
            // Overlay (thin, floats on top, auto-hides) rather than whatever the system-wide
            // default resolves to — a mouse-connected machine defaults to "legacy," a
            // persistent scroller that reserves real width from the clip view. That reserved
            // width doesn't shrink this table's already-laid-out column, so switches (anchored
            // to the row view's trailing edge, which tracks column width) ended up rendering
            // partway behind the scroller track. Overlay-style takes no layout space at all,
            // sidestepping the mismatch entirely rather than trying to precisely compute and
            // subtract a scroller width from the column.
            scrollView.scrollerStyle = .overlay
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            // A minimum, not a fixed height — this view is the one that should absorb
            // whatever extra vertical space the window has (see buildContent()'s hugging
            // priority comment), rather than staying pinned to a constant.
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
            scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
            listView = scrollView
        }

        let stack = NSStackView(views: [header, listView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // header keeps its intrinsic size; listView (the scroll view, when there are apps)
        // is the low-hugging-priority view that should stretch — see above.
        header.setContentHuggingPriority(.required, for: .vertical)
        return stack
    }

    /// Retained because NSTableView holds dataSource/delegate weakly — without this the
    /// object would be deallocated immediately after buildContent() returns.
    private var appListDataSource: AppListDataSource?

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

    // MARK: - Actions

    @objc private func loginToggleChanged(_ sender: NSSwitch) {
        LoginItemManager.setEnabled(sender.state == .on)
        // Re-read status rather than assuming success (e.g. requiresApproval, or a failure).
        sender.state = LoginItemManager.isEnabled ? .on : .off
    }

    @objc private func providerChanged(_ sender: NSSegmentedControl) {
        SummarizerPreferenceStore.current = sender.selectedSegment == 0 ? .onDevice : .anthropic
        onSummarizerPreferenceChanged?()
        refresh() // API key row's visibility depends on the selected provider
    }

    @objc private func apiKeyButtonClicked() {
        if APIKeyStore.load() != nil {
            APIKeyStore.clear()
            Log.write("Anthropic API key cleared from Keychain.\n")
            refresh()
            return
        }

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
        refresh()
    }
}

/// Backs the app-summarization list's NSTableView — a plain NSObject rather than folding
/// this into SettingsWindowController itself, since NSTableViewDataSource/Delegate's
/// numberOfRows/viewFor-row methods read more clearly as their own small type.
private final class AppListDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let apps: [NSRunningApplication]

    init(apps: [NSRunningApplication]) {
        self.apps = apps
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        apps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = apps[row]
        guard let bundleIdentifier = app.bundleIdentifier else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("AppToggleRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? AppToggleRowView) ?? AppToggleRowView(identifier: identifier)
        rowView.configure(app: app, bundleIdentifier: bundleIdentifier)
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        36
    }
}

/// One row: app icon, name (leading, expands to fill), switch (trailing, pinned to the
/// row's edge regardless of name length — this is the "list view with right-aligned
/// switches" layout, as opposed to the earlier version's switch sitting immediately after
/// whatever-width the name happened to be).
private final class AppToggleRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private var bundleIdentifier: String = ""

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .systemFont(ofSize: 13)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        // .regular (the default) renders noticeably larger than the switches System Settings
        // uses in its own per-app lists — .small matches that convention.
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)

        addSubview(iconView)
        addSubview(nameField)
        addSubview(toggle)

        NSLayoutConstraint.activate([
            // 2, not the earlier 14 — that sat noticeably right of the section header/
            // description text above, which has no equivalent extra indent of its own.
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),

            // -16, not the row's raw edge: .inset table style draws its rounded-rect row
            // background inset from the row's actual bounds, so content sitting only a few
            // points from that raw edge visually crowds/crosses the background's rounded
            // corner instead of sitting cleanly inside it.
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func configure(app: NSRunningApplication, bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        iconView.image = app.icon
        nameField.stringValue = app.localizedName ?? bundleIdentifier
        toggle.state = AppSummarizationPreferenceStore.isEnabled(bundleIdentifier: bundleIdentifier) ? .on : .off
    }

    @objc private func toggleChanged() {
        AppSummarizationPreferenceStore.setEnabled(toggle.state == .on, forBundleIdentifier: bundleIdentifier)
    }
}
