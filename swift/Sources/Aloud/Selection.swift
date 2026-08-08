import AppKit
import ApplicationServices

/// Read the current selection from whatever app has focus.
///
/// Two paths, best first:
///  1. The Accessibility API — native text views expose their selection
///     directly, no clipboard involved.
///  2. A synthesised ⌘C round-trip — Electron apps (VS Code, Cursor, Slack,
///     Discord) don't answer the AX query, but they all answer Copy. The
///     clipboard is saved and restored around it.
enum SelectionCapture {
    enum CaptureError: Error {
        case notTrusted
    }

    static let copyTimeout: TimeInterval = 0.6

    static func capture(restoreClipboard: Bool) throws -> String {
        if let text = accessibilitySelection(), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try clipboardSelection(restore: restoreClipboard)
    }

    // MARK: - AX path

    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedRef as! AXUIElement

        var selectedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                focused, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
            let text = selectedRef as? String
        else { return nil }
        return text
    }

    // MARK: - Clipboard path

    private static func clipboardSelection(restore: Bool) throws -> String {
        guard AXIsProcessTrusted() else { throw CaptureError.notTrusted }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount

        pressCopy()

        let deadline = Date().addingTimeInterval(copyTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != before { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != before else {
            // Nothing was selected, or the app ignored the keystroke.
            return ""
        }

        let text = pasteboard.string(forType: .string) ?? ""

        if restore, let previous {
            // Give the app a beat to finish writing before we overwrite it.
            Thread.sleep(forTimeInterval: 0.05)
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pressCopy() {
        let keyC: CGKeyCode = 8
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: keyC, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyC, keyDown: false)
        else { return }
        // Explicit flags: the user's hotkey modifiers may still be held.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
