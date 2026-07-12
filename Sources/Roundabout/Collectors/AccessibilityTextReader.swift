import AppKit
import ApplicationServices

/// Reads visible on-screen text from an app's focused window via the Accessibility API —
/// the same tree VoiceOver uses. Requires only the Accessibility permission Roundabout
/// already needs for its global hotkey; no per-app setup, no extra permission prompt.
///
/// Can only ever see whatever's actually rendered on screen right now (confirmed via
/// testing against real pages): a background browser tab that isn't the one currently
/// selected/visible in its window has no live content here, since browsers don't paint —
/// or keep a materialized accessibility tree for — tabs that aren't on screen. That's not
/// a limitation callers need to work around; it's *why* this is safe to rely on: it should
/// only ever be called for a context already known to be genuinely active (on screen right
/// now), which is exactly the case where this works.
///
/// Not Safari-specific — `bundleIdentifier` is a parameter so this could later back
/// summarization for other apps with rich accessibility trees (Pages, Keynote, Mail, ...),
/// not just Safari/Terminal.
enum AccessibilityTextReader {
    /// Walks the focused window's accessibility tree for the frontmost running instance of
    /// `bundleIdentifier`, collecting AXValue/AXTitle/AXDescription text from every node.
    /// `maxNodes` is a safety valve, not a tuned limit — tested against a complex real page
    /// (a GitHub repo view) at 788 nodes / ~0.1s, so 20,000 is generous headroom, not a
    /// realistic ceiling for a normal page or document.
    static func fetchVisibleText(bundleIdentifier: String, maxCharacters: Int = 4000, maxNodes: Int = 20_000) -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return nil
        }
        let windowElement = window as! AXUIElement // swiftlint:disable:this force_cast — type-checked above via CFGetTypeID

        var collected: [String] = []
        var nodeCount = 0
        func walk(_ element: AXUIElement) {
            nodeCount += 1
            guard nodeCount <= maxNodes else { return }
            if let value = stringAttribute(element, kAXValueAttribute), !value.isEmpty {
                collected.append(value)
            } else if let title = stringAttribute(element, kAXTitleAttribute), !title.isEmpty {
                collected.append(title)
            } else if let description = stringAttribute(element, kAXDescriptionAttribute), !description.isEmpty {
                collected.append(description)
            }
            for child in childElements(element) {
                walk(child)
            }
        }
        walk(windowElement)

        let text = collected.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(maxCharacters))
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
