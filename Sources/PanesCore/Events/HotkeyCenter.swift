import AppKit
import Carbon.HIToolbox
import os

/// Global hotkeys via Carbon `RegisterEventHotKey`.
///
/// Chosen deliberately over CGEventTap/NSEvent monitors because it:
///  - requires NO TCC permission at all,
///  - consumes the keystroke (the frontmost app never sees it),
///  - costs nothing while idle (no per-event callback).
///
/// Known limitation shared by every hotkey mechanism: hotkeys do not fire
/// while Secure Event Input is active (password fields, Terminal's "Secure
/// Keyboard Entry"). Detect with `IsSecureEventInputEnabled()` if you need
/// to explain dead hotkeys to the user.
@MainActor
public final class HotkeyCenter {
    public nonisolated struct Spec: Hashable, Sendable {
        /// Virtual key code (`kVK_ANSI_S` etc. from Carbon.HIToolbox).
        public let keyCode: UInt32
        /// Carbon modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).
        public let carbonModifiers: UInt32

        public init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }
    }

    public nonisolated struct Token: Hashable, Sendable {
        fileprivate let id: UInt32
    }

    private static let signature: FourCharCode = 0x50414E45 // 'PANE'

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var specs: [UInt32: Spec] = [:]
    private var nextID: UInt32 = 1
    private var carbonHandler: EventHandlerRef?
    private var suspended = false
    private let log = Logger.panes("hotkeys")

    public init() {}

    @discardableResult
    public func register(_ spec: Spec, handler: @escaping () -> Void) -> Token? {
        installCarbonHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        specs[id] = spec
        // While suspended (a shortcut is being recorded) keep the handler and
        // spec but don't claim the key combo yet; resume() registers it.
        if !suspended { registerRef(id: id, spec: spec) }
        return Token(id: id)
    }

    public func unregister(_ token: Token) {
        if let ref = hotKeyRefs.removeValue(forKey: token.id) {
            UnregisterEventHotKey(ref)
        }
        handlers[token.id] = nil
        specs[token.id] = nil
    }

    /// Temporarily release every registered combo so the keys flow to the app
    /// (used while the user records a new shortcut, so a combo that overlaps an
    /// existing binding can still be captured instead of firing it). Pair with
    /// `resume()`.
    public func suspend() {
        guard !suspended else { return }
        suspended = true
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    public func resume() {
        guard suspended else { return }
        suspended = false
        for (id, spec) in specs where hotKeyRefs[id] == nil {
            registerRef(id: id, spec: spec)
        }
    }

    private func registerRef(id: UInt32, spec: Spec) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed: \(status)")
            return
        }
        hotKeyRefs[id] = ref
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installCarbonHandlerIfNeeded() {
        guard carbonHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            refcon,
            &carbonHandler
        )
    }
}

/// C-convention trampoline; Carbon dispatches on the main thread.
private nonisolated func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.fire(id: hotKeyID.id)
    }
    return noErr
}
