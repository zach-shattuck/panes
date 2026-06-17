import AppKit
import Carbon.HIToolbox

/// Maps characters to virtual key codes for the user's CURRENT keyboard
/// layout, so synthesized shortcuts (Cmd+V paste-back, Finder Cmd+C / Cmd+X /
/// Cmd+Opt+V) hit the right physical key.
///
/// Why this matters: a hard-coded `kVK_ANSI_V` is a POSITIONAL code. On
/// AZERTY, Dvorak, Colemak, etc. that position is not "v", so the synthesized
/// "Cmd+V" pastes nothing (or fires the wrong app shortcut). We instead ask
/// the active Unicode layout which key produces the character we want.
///
/// The lookup is cached and invalidated when the input source changes
/// (`kTISNotifySelectedKeyboardInputSourceChanged`), so the per-keystroke
/// path is a dictionary hit.
@MainActor
public final class KeyboardLayout {
    public static let shared = KeyboardLayout()

    private var cache: [Character: CGKeyCode] = [:]

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { KeyboardLayout.shared.cache.removeAll() }
        }
    }

    /// The virtual key code that produces `character` (lowercase, no
    /// modifiers) on the active layout, or nil if the layout can't be read.
    public func keyCode(for character: Character) -> CGKeyCode? {
        if let cached = cache[character] { return cached }
        guard let code = Self.lookup(character) else { return nil }
        cache[character] = code
        return code
    }

    /// The character a key produces with no modifiers on the active layout, or
    /// nil if it can't be read. Used to label a recorded shortcut; not cached
    /// since it's only hit when drawing the Settings UI.
    public func character(for keyCode: CGKeyCode) -> Character? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        let kbdType = UInt32(LMGetKbdType())
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var realLength = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                base,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                kbdType,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &realLength,
                &chars
            )
        }
        guard status == noErr, realLength > 0, let scalar = UnicodeScalar(chars[0]) else { return nil }
        return Character(scalar)
    }

    private static func lookup(_ character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        let kbdType = UInt32(LMGetKbdType())
        for keyCode: CGKeyCode in 0..<128 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var realLength = 0
            let status = layoutData.withUnsafeBytes { raw -> OSStatus in
                guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return OSStatus(paramErr)
                }
                return UCKeyTranslate(
                    base,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0, // no modifiers
                    kbdType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &realLength,
                    &chars
                )
            }
            guard status == noErr, realLength > 0, let scalar = UnicodeScalar(chars[0]) else { continue }
            if Character(scalar) == character {
                return keyCode
            }
        }
        return nil
    }
}
