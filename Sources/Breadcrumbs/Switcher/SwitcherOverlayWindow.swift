import AppKit

/// The Option+Tab overlay: a vertical, glass-paneled list of contexts. One
/// top-level NSGlassEffectView provides the real Liquid Glass material for the
/// panel; each row is a plain layered view so highlighting stays simple and
/// doesn't nest glass-in-glass (unsupported z-ordering per Apple's docs).
final class SwitcherWindowController {
    var maxVisibleSlots: Int = 15

    private let panel: NSPanel
    private let glass: NSGlassEffectView
    private let stack = NSStackView()

    private var rows: [ContextRowView] = []
    private var contexts: [Context] = []
    private(set) var selectedIndex: Int = 0

    private static let minRowHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 4
    private static let panelPadding: CGFloat = 10
    private static let panelWidth: CGFloat = 340

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.minRowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar + 2
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 22

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.rowSpacing
        stack.edgeInsets = NSEdgeInsets(
            top: Self.panelPadding, left: Self.panelPadding,
            bottom: Self.panelPadding, right: Self.panelPadding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        glass.contentView = stack
        panel.contentView = glass
    }

    /// Shows the overlay with a fresh context list and selects the second item
    /// (the "most recent other context"), mirroring Cmd-Tab's first-press behavior.
    /// A reversed first press starts from the far end of the list instead, matching
    /// Cmd-Shift-Tab's "one step back" semantics.
    func show(contexts: [Context], reverse: Bool = false) {
        self.contexts = Array(contexts.prefix(maxVisibleSlots))
        if self.contexts.count > 1 {
            selectedIndex = reverse ? self.contexts.count - 1 : 1
        } else {
            selectedIndex = 0
        }
        rebuildRows()
        layoutPanel()
        highlightSelection()
        panel.orderFrontRegardless()
    }

    func advance() {
        guard !contexts.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % contexts.count
        highlightSelection()
    }

    func retreat() {
        guard !contexts.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + contexts.count) % contexts.count
        highlightSelection()
    }

    /// Hides the panel and returns whichever context was selected, if any.
    @discardableResult
    func commitAndHide() -> Context? {
        panel.orderOut(nil)
        guard contexts.indices.contains(selectedIndex) else { return nil }
        return contexts[selectedIndex]
    }

    var isVisible: Bool { panel.isVisible }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = contexts.map {
            ContextRowView(context: $0, minHeight: Self.minRowHeight, width: Self.panelWidth - 2 * Self.panelPadding)
        }
        rows.forEach { stack.addArrangedSubview($0) }
    }

    private func highlightSelection() {
        for (index, row) in rows.enumerated() {
            row.setSelected(index == selectedIndex)
        }
    }

    private func layoutPanel() {
        // Rows now size themselves (summaries wrap instead of truncating), so ask the
        // stack for its fitted size rather than assuming a fixed height per row.
        stack.layoutSubtreeIfNeeded()
        let fitted = stack.fittingSize
        let minHeight = Self.minRowHeight + 2 * Self.panelPadding

        guard let screen = NSScreen.main else {
            panel.setContentSize(NSSize(width: Self.panelWidth, height: max(fitted.height, minHeight)))
            return
        }
        let frame = screen.frame
        let maxHeight = frame.height * 0.85
        let size = NSSize(width: Self.panelWidth, height: min(max(fitted.height, minHeight), maxHeight))
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
