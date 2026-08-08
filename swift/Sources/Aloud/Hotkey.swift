import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey.
///
/// Unlike an event tap this needs no Accessibility or Input Monitoring
/// permission, integrates with the existing run loop, and swallows nothing —
/// the perfect fit for a menu bar app. Combo strings use the pynput syntax
/// from the Python version ("<ctrl>+s") so config.json stays compatible.
final class HotkeyManager {
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    static func parse(_ combo: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for part in combo.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "<cmd>": modifiers |= UInt32(cmdKey)
            case "<ctrl>": modifiers |= UInt32(controlKey)
            case "<alt>": modifiers |= UInt32(optionKey)
            case "<shift>": modifiers |= UInt32(shiftKey)
            case let key:
                keyCode = keyCodes[key]
            }
        }
        guard let keyCode else { return nil }
        return (keyCode, modifiers)
    }

    static func pretty(_ combo: String) -> String {
        combo
            .replacingOccurrences(of: "<cmd>", with: "⌘")
            .replacingOccurrences(of: "<ctrl>", with: "⌃")
            .replacingOccurrences(of: "<alt>", with: "⌥")
            .replacingOccurrences(of: "<shift>", with: "⇧")
            .replacingOccurrences(of: "+", with: "")
            .uppercased()
    }

    @discardableResult
    func register(combo: String) -> Bool {
        unregister()
        guard let (keyCode, modifiers) = Self.parse(combo) else { return false }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async { manager.onPressed?() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x414C_4F44), id: 1)  // 'ALOD'
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
