import AppKit
import Carbon.HIToolbox

/// Renders a `HotkeyCenter.Spec` as the familiar glyph string (e.g. "⌃⌥←",
/// "⌘⇧V") and converts recorded `NSEvent` modifier flags into Carbon flags.
/// Shared by the Settings shortcut recorder.
public enum HotkeySymbols {
    /// Carbon modifier mask from the flags on a recorded key event.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Glyphs in Apple's canonical order: Control, Option, Shift, Command.
    public static func modifierString(_ carbon: UInt32) -> String {
        var out = ""
        if carbon & UInt32(controlKey) != 0 { out += "⌃" }
        if carbon & UInt32(optionKey) != 0 { out += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    public static func string(_ spec: HotkeyCenter.Spec) -> String {
        modifierString(spec.carbonModifiers) + keyName(spec.keyCode)
    }

    /// A human label for a virtual key code: a glyph for known special keys,
    /// otherwise the character that key produces on the active layout.
    public static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        if let character = KeyboardLayout.shared.character(for: CGKeyCode(keyCode)) {
            return String(character).uppercased()
        }
        return "Key \(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Space: "Space",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "↖",
        kVK_End: "↘",
        kVK_PageUp: "⇞",
        kVK_PageDown: "⇟",
        kVK_ANSI_KeypadEnter: "⌅",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
