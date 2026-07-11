import AppKit
import Carbon.HIToolbox

/// Watches system-wide keyboard events for an Option+Tab cycle, the same shape
/// as Cmd-Tab: each Tab press while Option is held advances the selection, and
/// releasing Option commits it. Requires Accessibility (Input Monitoring) trust.
final class HotkeyManager {
    /// Called on each Tab press while Option is held. `reverse` is true when Shift
    /// is also held, mirroring Cmd-Shift-Tab's reverse-direction cycling.
    var onOptionTab: ((_ reverse: Bool) -> Void)?
    var onOptionReleased: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isOptionDown = false

    /// Checks (and, if needed, prompts for) Accessibility trust. The event tap
    /// this class creates silently produces no events at all without it.
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [promptKey: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Plain trust check, no prompt — used by AppDelegate to poll for the permission being
    /// granted *after* a launch that found it missing, so the user doesn't have to quit and
    /// relaunch once they flip the switch in System Settings. Repeatedly calling
    /// ensureAccessibilityPermission() instead would needlessly re-trigger the system's
    /// permission dialog/Dock-bounce on every poll.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func start() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(proxy: proxy, type: type, event: event, tap: manager.eventTap)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("Failed to create event tap — check Accessibility permission for Roundabout\n")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("Event tap created and enabled successfully.\n")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, tap: CFMachPort?) -> Unmanaged<CGEvent>? {
        // The system disables a tap that's too slow or misbehaves; just re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let optionNowDown = event.flags.contains(.maskAlternate)
            if isOptionDown && !optionNowDown {
                isOptionDown = false
                onOptionReleased?()
            } else {
                isOptionDown = optionNowDown
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if isOptionDown && keyCode == Int64(kVK_Tab) {
                let reverse = event.flags.contains(.maskShift)
                onOptionTab?(reverse)
                return nil // swallow — don't let Tab reach the frontmost app while cycling
            }
        }

        return Unmanaged.passRetained(event)
    }
}
