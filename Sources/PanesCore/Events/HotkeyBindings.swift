import Foundation
import os

/// Resolves each module's rebindable shortcut to a current `HotkeyCenter.Spec`
/// (the user's override from PreferencesStore, else the declared default) and
/// keeps live registrations in sync: when a binding changes in Settings, the
/// running module's hotkey is re-registered with no restart.
///
/// Modules bind through here instead of calling `HotkeyCenter` directly. The
/// catalog of known actions is populated from every module's metadata at
/// launch, so Settings can render and reset a shortcut even while its module
/// is disabled.
@MainActor
public final class HotkeyBindings {
    public nonisolated struct BindingToken: Hashable, Sendable {
        fileprivate let id: Int
    }

    private struct Active {
        let actionID: String
        let build: (HotkeyCenter.Spec, HotkeyCenter) -> [HotkeyCenter.Token]
        var tokens: [HotkeyCenter.Token]
    }

    private let center: HotkeyCenter
    private let preferences: PreferencesStore
    private var catalog: [String: HotkeyAction] = [:]
    private var active: [Int: Active] = [:]
    private var nextID = 1
    private let log = Logger.panes("hotkey-bindings")

    public init(center: HotkeyCenter, preferences: PreferencesStore) {
        self.center = center
        self.preferences = preferences
        preferences.observe { [weak self] key in self?.preferenceChanged(key) }
    }

    /// Records the actions a module declares so they can be resolved and edited
    /// regardless of whether the module is currently running. Idempotent.
    public func registerCatalog(_ actions: [HotkeyAction]) {
        for action in actions { catalog[action.id] = action }
    }

    // MARK: Resolution

    private static func key(_ id: String) -> String { "hotkey.\(id)" }

    /// The default declared in metadata (nil for an unknown action id).
    public func defaultSpec(for id: String) -> HotkeyCenter.Spec? {
        catalog[id]?.defaultSpec
    }

    /// The shortcut currently in effect: the user's override if set, else the
    /// declared default.
    public func spec(for id: String) -> HotkeyCenter.Spec? {
        guard let fallback = catalog[id]?.defaultSpec else { return nil }
        guard let raw = preferences.string(forKey: Self.key(id)) else { return fallback }
        let parts = raw.split(separator: ",")
        guard parts.count == 2, let keyCode = UInt32(parts[0]), let mods = UInt32(parts[1]) else {
            return fallback
        }
        return HotkeyCenter.Spec(keyCode: keyCode, carbonModifiers: mods)
    }

    public func isCustomized(_ id: String) -> Bool {
        preferences.string(forKey: Self.key(id)) != nil
    }

    /// Persists a new shortcut; any running binding re-registers via the
    /// preference observer.
    public func setSpec(_ spec: HotkeyCenter.Spec, for id: String) {
        preferences.set("\(spec.keyCode),\(spec.carbonModifiers)", forKey: Self.key(id))
    }

    /// Clears the override so the action falls back to its default.
    public func reset(_ id: String) {
        preferences.removeValue(forKey: Self.key(id))
    }

    // MARK: Recording

    /// Frees all combos while the user records a new one, so a combo that
    /// overlaps an existing binding is captured rather than fired.
    public func beginRecording() { center.suspend() }
    public func endRecording() { center.resume() }

    // MARK: Binding

    /// Binds an action to one or more concrete registrations. `build` receives
    /// the resolved spec and the center; it returns the tokens it created and
    /// is re-run whenever the binding changes. Use this when a module derives
    /// extra hotkeys from the primary spec (e.g. a reverse variant).
    @discardableResult
    public func bind(
        _ id: String,
        build: @escaping (HotkeyCenter.Spec, HotkeyCenter) -> [HotkeyCenter.Token]
    ) -> BindingToken? {
        guard let spec = spec(for: id) else {
            log.error("bind: unknown hotkey action \(id, privacy: .public)")
            return nil
        }
        let token = BindingToken(id: nextID)
        nextID += 1
        active[token.id] = Active(actionID: id, build: build, tokens: build(spec, center))
        return token
    }

    /// Convenience for a single shortcut with one handler.
    @discardableResult
    public func bind(_ id: String, handler: @escaping () -> Void) -> BindingToken? {
        bind(id) { spec, center in
            center.register(spec, handler: handler).map { [$0] } ?? []
        }
    }

    public func unbind(_ token: BindingToken?) {
        guard let token, let entry = active.removeValue(forKey: token.id) else { return }
        for t in entry.tokens { center.unregister(t) }
    }

    private func preferenceChanged(_ key: String) {
        // Snapshot ids so we can mutate `active` inside the loop safely.
        for tid in Array(active.keys) {
            guard var entry = active[tid], key == Self.key(entry.actionID) else { continue }
            guard let newSpec = spec(for: entry.actionID) else { continue }
            for t in entry.tokens { center.unregister(t) }
            entry.tokens = entry.build(newSpec, center)
            active[tid] = entry
        }
    }
}
