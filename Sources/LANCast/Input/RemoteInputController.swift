import Foundation
import CoreGraphics
import ApplicationServices

/// Mouse button forwarded from the client.
enum MouseButton {
    case left
    case right
}

/// Keyboard modifier state forwarded from the client.
struct KeyModifiers {
    var shift = false
    var ctrl = false
    var alt = false
    var meta = false
}

/// A single remote input action. Coordinates are normalized [0,1] relative to
/// the streamed display.
enum InputEvent {
    case move(x: Double, y: Double)
    case mouseDown(x: Double, y: Double, button: MouseButton)
    case mouseUp(x: Double, y: Double, button: MouseButton)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case key(down: Bool, code: String, char: String?, mods: KeyModifiers)
    /// Unicode text typed via a soft keyboard (no usable key code).
    case text(String)
}

/// Injects remote input on the host via CoreGraphics events. Normalized
/// coordinates are mapped to the streamed display's global bounds. Requires the
/// app to be trusted for Accessibility.
final class RemoteInputController {

    /// CGDirectDisplayID of the display being controlled (0 = main).
    var displayID: UInt32 = 0

    private let queue = DispatchQueue(label: "lancast.input")
    private let source = CGEventSource(stateID: .combinedSessionState)
    private var leftDown = false
    private var rightDown = false

    // MARK: - Accessibility permission

    static func hasAccessibility() -> Bool { AXIsProcessTrusted() }

    /// Returns current trust and, if untrusted, asks the system to show the
    /// Accessibility prompt.
    @discardableResult
    static func requestAccessibility() -> Bool {
        // Literal key value ("AXTrustedCheckOptionPrompt") avoids CFString vs.
        // Unmanaged ambiguity of kAXTrustedCheckOptionPrompt across SDKs.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Public

    func handle(_ event: InputEvent) {
        queue.async { [weak self] in self?.process(event) }
    }

    /// Releases any held mouse buttons (e.g. when the controller disconnects
    /// mid-drag) so the host isn't left with a stuck button.
    func releaseHeld() {
        queue.async { [weak self] in
            guard let self else { return }
            let p = CGEvent(source: self.source)?.location ?? .zero
            if self.leftDown { self.post(mouse: .leftMouseUp, at: p, button: .left); self.leftDown = false }
            if self.rightDown { self.post(mouse: .rightMouseUp, at: p, button: .right); self.rightDown = false }
        }
    }

    // MARK: - Processing

    private func displayBounds() -> CGRect {
        let bounds = CGDisplayBounds(CGDirectDisplayID(displayID))
        if bounds.width > 0 && bounds.height > 0 { return bounds }
        return CGDisplayBounds(CGMainDisplayID())
    }

    private func point(_ nx: Double, _ ny: Double) -> CGPoint {
        let b = displayBounds()
        let cx = max(0.0, min(1.0, nx))
        let cy = max(0.0, min(1.0, ny))
        return CGPoint(x: b.origin.x + cx * b.width, y: b.origin.y + cy * b.height)
    }

    private func process(_ event: InputEvent) {
        switch event {
        case let .move(x, y):
            let p = point(x, y)
            let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
            post(mouse: type, at: p, button: rightDown ? .right : .left)

        case let .mouseDown(x, y, button):
            let p = point(x, y)
            if button == .left { leftDown = true; post(mouse: .leftMouseDown, at: p, button: .left) }
            else { rightDown = true; post(mouse: .rightMouseDown, at: p, button: .right) }

        case let .mouseUp(x, y, button):
            let p = point(x, y)
            if button == .left { leftDown = false; post(mouse: .leftMouseUp, at: p, button: .left) }
            else { rightDown = false; post(mouse: .rightMouseUp, at: p, button: .right) }

        case let .scroll(x, y, dx, dy):
            // Position the cursor first so the scroll hits the right element.
            post(mouse: .mouseMoved, at: point(x, y), button: .left)
            let wheelY = Int32(clamping: Int((-dy).rounded()))
            let wheelX = Int32(clamping: Int((-dx).rounded()))
            if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                               wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }

        case let .key(down, code, char, mods):
            postKey(down: down, code: code, char: char, mods: mods)

        case let .text(string):
            if !string.isEmpty { typeUnicode(string) }
        }
    }

    private func post(mouse type: CGEventType, at p: CGPoint, button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: button) else { return }
        e.post(tap: .cghidEventTap)
    }

    private func cgFlags(_ m: KeyModifiers) -> CGEventFlags {
        var f = CGEventFlags()
        if m.shift { f.insert(.maskShift) }
        if m.ctrl { f.insert(.maskControl) }
        if m.alt { f.insert(.maskAlternate) }
        if m.meta { f.insert(.maskCommand) }
        return f
    }

    private func postKey(down: Bool, code: String, char: String?, mods: KeyModifiers) {
        let flags = cgFlags(mods)
        if let vk = Self.keyCode(for: code) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
            e.flags = flags
            e.post(tap: .cghidEventTap)
            return
        }
        // Layout-independent fallback for printable characters we have no key
        // code for (only on key-down, and not while a command/control chord is
        // active since that's meant as a shortcut).
        if down, !mods.ctrl, !mods.meta, !mods.alt, let ch = char, ch.count == 1, ch != " " {
            typeUnicode(ch)
        }
    }

    private func typeUnicode(_ s: String) {
        let utf16 = Array(s.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key code table (KeyboardEvent.code -> macOS virtual key, ANSI)

    private static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5,
        "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12,
        "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
        "KeyO": 31, "KeyU": 32, "KeyI": 34, "KeyP": 35, "KeyL": 37, "KeyJ": 38,
        "KeyK": 40, "KeyN": 45, "KeyM": 46,
        "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit5": 23,
        "Digit6": 22, "Digit7": 26, "Digit8": 28, "Digit9": 25, "Digit0": 29,
        "Equal": 24, "Minus": 27, "BracketRight": 30, "BracketLeft": 33,
        "Quote": 39, "Semicolon": 41, "Backslash": 42, "Comma": 43,
        "Slash": 44, "Period": 47, "Backquote": 50,
        "Return": 36, "Enter": 36, "NumpadEnter": 76,
        "Tab": 48, "Space": 49, "Backspace": 51, "Escape": 53, "Delete": 117,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
        "ShiftLeft": 56, "ShiftRight": 60, "ControlLeft": 59, "ControlRight": 62,
        "AltLeft": 58, "AltRight": 61, "MetaLeft": 55, "MetaRight": 54,
        "CapsLock": 57,
        "Numpad0": 82, "Numpad1": 83, "Numpad2": 84, "Numpad3": 85,
        "Numpad4": 86, "Numpad5": 87, "Numpad6": 88, "Numpad7": 89,
        "Numpad8": 91, "Numpad9": 92, "NumpadDecimal": 65, "NumpadAdd": 69,
        "NumpadSubtract": 78, "NumpadMultiply": 67, "NumpadDivide": 75,
    ]

    static func keyCode(for code: String) -> CGKeyCode? { keyCodes[code] }
}
