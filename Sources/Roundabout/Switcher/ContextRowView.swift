import AppKit

/// One row in the switcher: accent dot, app icon, and a title/summary block. The
/// summary wraps rather than truncating, so the row's height is intrinsic —
/// callers should size the panel from the stack's fitted size, not a fixed constant.
final class ContextRowView: NSView {
    private let highlightLayer = CALayer()
    private let accentColor: NSColor
    private var trackingArea: NSTrackingArea?

    /// Set by callers that want this row to be clickable (currently only
    /// StatusItemController's status-bar dropdown — the Option-Tab switcher panel sets
    /// `ignoresMouseEvents = true` on its whole window, so these never fire there, and
    /// leaving this nil there is enough to keep the row inert). When set, the row hover-
    /// highlights (reusing `setSelected`, the same highlight the switcher drives via the
    /// keyboard) and a click invokes it and dismisses the enclosing menu.
    var onSelect: (() -> Void)?

    init(context: Context, minHeight: CGFloat, width: CGFloat) {
        accentColor = context.accentColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true

        wantsLayer = true
        highlightLayer.cornerRadius = 12
        highlightLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(highlightLayer)

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = accentColor.cgColor
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = Self.icon(forAppNamed: context.app)
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let titleField = NSTextField(labelWithString: context.label)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.textColor = .labelColor

        // Domain is cheap/mechanical (parsed straight from the URL, no AI involved) and shown
        // whenever this is a browser context — unlike summary below, it doesn't need to wait
        // on an async result, so a Safari row reads title/domain immediately, summary once
        // it's ready.
        let domainField = NSTextField(labelWithString: context.domain ?? "")
        domainField.font = .systemFont(ofSize: 11)
        domainField.textColor = .tertiaryLabelColor
        domainField.isHidden = context.domain == nil

        let summaryField = NSTextField(wrappingLabelWithString: context.summary ?? "")
        summaryField.font = .systemFont(ofSize: 11)
        summaryField.textColor = .secondaryLabelColor
        summaryField.maximumNumberOfLines = 4
        summaryField.isHidden = context.summary == nil

        // Fixed left-hand chrome width: 12 leading inset + 8 dot + 10 spacing + 24 icon + 10 spacing + 12 trailing inset.
        let textWidth = width - (12 + 8 + 10 + 24 + 10 + 12)
        summaryField.preferredMaxLayoutWidth = textWidth
        titleField.preferredMaxLayoutWidth = textWidth
        domainField.preferredMaxLayoutWidth = textWidth

        let textStack = NSStackView(views: [titleField, domainField, summaryField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        let rowStack = NSStackView(views: [dot, icon, textStack])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
    }

    func setSelected(_ selected: Bool) {
        highlightLayer.backgroundColor = selected ? accentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard onSelect != nil else { return }
        setSelected(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard onSelect != nil else { return }
        setSelected(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onSelect else {
            super.mouseDown(with: event)
            return
        }
        // enclosingMenuItem is exactly the hook AppKit provides for a custom NSMenuItem.view
        // to close its own menu — cancelTracking() dismisses the dropdown immediately,
        // before activating the target context, so the menu doesn't linger on top of it.
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect()
    }

    private static func icon(forAppNamed name: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return running.icon
        }
        return NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
    }
}
