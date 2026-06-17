import AppKit
import PanesCore

/// Owns whether Panes shows in the Dock and in the menu bar, so the menu and
/// the Settings window can both flip them and stay in sync. Settings persist
/// in PreferencesStore.
///
/// Recovery note: if BOTH are hidden, Panes has no visible UI — but launching
/// it again (Spotlight / Raycast / Finder) reopens Settings via the app's
/// reopen handler, so it's never lost.
@MainActor
final class AppChrome {
    static let showInDockKey = "app.showInDock"
    static let hideMenuBarKey = "app.hideMenuBarIcon"

    private let preferences: PreferencesStore
    private let applyStatusItemVisible: (Bool) -> Void

    init(preferences: PreferencesStore, applyStatusItemVisible: @escaping (Bool) -> Void) {
        self.preferences = preferences
        self.applyStatusItemVisible = applyStatusItemVisible
    }

    var hiddenFromDock: Bool { !preferences.bool(forKey: Self.showInDockKey, default: false) }
    var hiddenFromMenuBar: Bool { preferences.bool(forKey: Self.hideMenuBarKey, default: false) }

    /// Apply current settings (call once at launch).
    func apply() {
        applyDock()
        applyMenuBar()
    }

    func setHiddenFromDock(_ hidden: Bool) {
        preferences.set(!hidden, forKey: Self.showInDockKey)
        applyDock()
    }

    func setHiddenFromMenuBar(_ hidden: Bool) {
        preferences.set(hidden, forKey: Self.hideMenuBarKey)
        applyMenuBar()
    }

    private func applyDock() {
        // .accessory = no Dock icon (menu-bar app); .regular = shows in Dock.
        NSApp.setActivationPolicy(hiddenFromDock ? .accessory : .regular)
    }

    private func applyMenuBar() {
        applyStatusItemVisible(!hiddenFromMenuBar)
    }
}
