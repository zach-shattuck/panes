import AppKit
import Carbon.HIToolbox
import PanesCore

/// A per-window switcher on Option+Tab — Windows Alt+Tab muscle memory, but
/// switching individual windows (not just apps) with live previews.
///
/// Interaction: Option+Tab opens the switcher and advances selection; each
/// further Option+Tab (Carbon re-fires the hotkey while Option is held)
/// advances again; Option+Shift+Tab goes back. Releasing Option chooses the
/// highlighted window; arrows reposition; Return chooses; Esc cancels.
public final class AltTabSwitcherModule: FeatureModule {
    static let groupByAppKey = "alt-tab.groupByApp"
    static let maxPerRowKey = "alt-tab.maxPerRow"

    public let metadata = ModuleMetadata(
        id: "alt-tab-switcher",
        displayName: "Window Switcher",
        category: "Window Management",
        summary: "Switch between individual windows, not just whole apps, with a live preview of each one.",
        howToUse: "Hold the modifier in the shortcut below and tap its key to open the switcher and step through your windows. Add Shift to step backward. Let go of the modifier to jump to the highlighted window. You can also use the arrow keys to move, Return to confirm, and Esc to cancel. If another app already uses this shortcut, change it here or quit that app to avoid conflicts.",
        requiredPermissions: [.accessibility, .screenRecording],
        options: [
            .toggle(
                key: groupByAppKey,
                title: "Group windows by app",
                detail: "Show one card per app instead of one for every window.",
                defaultOn: false
            ),
            .slider(
                key: maxPerRowKey,
                title: "Most windows per row",
                detail: "Wrap to a new row past this many. Panes also keeps it within your screen.",
                min: 4, max: 10, step: 1, unit: "", default: 7
            ),
        ],
        hotkeys: [
            HotkeyAction(
                id: "alt-tab-switcher.open",
                title: "Open the window switcher",
                defaultSpec: HotkeyCenter.Spec(keyCode: UInt32(kVK_Tab), carbonModifiers: UInt32(optionKey))
            )
        ]
    )

    private let enumerator = WindowEnumerator()
    private var panel: SwitcherPanel?
    private var bindingToken: HotkeyBindings.BindingToken?
    private weak var bindings: HotkeyBindings?
    private weak var eventTaps: EventTapHub?
    private weak var preferences: PreferencesStore?
    private var optionWatch: EventTapHub.Token?
    private var isOpening = false
    /// The modifier(s) held to keep the switcher open; releasing any of them
    /// commits the selection. Tracks the bound shortcut (Shift is excluded —
    /// it's the reverse-step toggle, not a hold key).
    private var holdFlags: NSEvent.ModifierFlags = .option

    public init() {}

    public func start(context: ModuleContext) {
        bindings = context.hotkeyBindings
        eventTaps = context.eventTaps
        preferences = context.preferences
        enumerator.prewarm()

        let panel = SwitcherPanel()
        panel.onChoose = { [weak self] item in
            self?.enumerator.raise(item)
            self?.close()
        }
        panel.onCancel = { [weak self] in self?.close() }
        self.panel = panel

        // One bound shortcut opens/steps forward; the same keys plus Shift step
        // backward. Re-runs automatically if the user rebinds it.
        bindingToken = context.hotkeyBindings.bind("alt-tab-switcher.open") { [weak self] spec, center in
            self?.holdFlags = Self.holdFlags(forCarbon: spec.carbonModifiers)
            var tokens: [HotkeyCenter.Token] = []
            if let forward = center.register(spec, handler: { self?.handleHotkey(forward: true) }) {
                tokens.append(forward)
            }
            let backwardSpec = HotkeyCenter.Spec(
                keyCode: spec.keyCode,
                carbonModifiers: spec.carbonModifiers ^ UInt32(shiftKey)
            )
            if let backward = center.register(backwardSpec, handler: { self?.handleHotkey(forward: false) }) {
                tokens.append(backward)
            }
            return tokens
        }
    }

    public func stop() {
        bindings?.unbind(bindingToken)
        bindingToken = nil
        close()
        panel = nil
    }

    /// The hold-to-keep-open flags for a bound spec: every modifier except
    /// Shift (which is reserved for stepping backward).
    private static func holdFlags(forCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags.isEmpty ? .option : flags
    }

    private func handleHotkey(forward: Bool) {
        guard let panel else { return }
        if panel.isVisible {
            panel.advance(by: forward ? 1 : -1)
            return
        }
        guard !isOpening else { return }
        isOpening = true
        Task { [weak self] in
            guard let self else { return }
            let enumerated = await self.enumerator.enumerate()
            self.isOpening = false
            let items = self.groupByApp ? Self.grouped(enumerated) : enumerated
            guard !items.isEmpty, let panel = self.panel, !panel.isVisible else { return }
            panel.maxPerRow = self.maxPerRow
            // Start on the second window (index 1) so a single Option+Tab
            // jumps to the most-recent other window, like Cmd-Tab.
            panel.show(items: items, initialSelection: forward ? min(1, items.count - 1) : items.count - 1)
            self.watchForOptionRelease()
        }
    }

    private var groupByApp: Bool {
        preferences?.bool(forKey: Self.groupByAppKey, default: false) ?? false
    }

    private var maxPerRow: Int {
        Int((preferences?.double(forKey: Self.maxPerRowKey, default: 7) ?? 7).rounded())
    }

    /// Collapse windows of the same app to a single representative card (its
    /// most-recent window), tagged with the app's window count.
    private static func grouped(_ items: [WindowEnumerator.Item]) -> [WindowEnumerator.Item] {
        var counts: [pid_t: Int] = [:]
        for item in items { counts[item.pid, default: 0] += 1 }
        var seen = Set<pid_t>()
        var result: [WindowEnumerator.Item] = []
        for item in items where seen.insert(item.pid).inserted {
            var representative = item
            representative.windowCount = counts[item.pid] ?? 1
            result.append(representative)
        }
        return result
    }

    /// While the switcher is open, releasing the held modifier commits the
    /// selection (mirrors Cmd-Tab). Follows whatever modifier is bound.
    private func watchForOptionRelease() {
        guard optionWatch == nil else { return }
        let required = Self.cgFlags(from: holdFlags)
        optionWatch = eventTaps?.subscribe(to: [.flagsChanged]) { [weak self] _, event in
            if !event.flags.contains(required) {
                self?.panel?.commitSelection()
            }
            return .pass
        }
    }

    /// Translate the AppKit hold flags to the CGEventFlags the event hub
    /// reports, so the release check compares like with like.
    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg: CGEventFlags = []
        if flags.contains(.control) { cg.insert(.maskControl) }
        if flags.contains(.option) { cg.insert(.maskAlternate) }
        if flags.contains(.command) { cg.insert(.maskCommand) }
        return cg
    }

    private func close() {
        if let token = optionWatch { eventTaps?.unsubscribe(token) }
        optionWatch = nil
        panel?.hide()
    }
}
