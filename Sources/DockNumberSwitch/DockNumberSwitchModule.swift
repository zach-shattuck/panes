import AppKit
import Carbon.HIToolbox
import PanesCore

/// Jump to an app by its position in the Dock with a keyboard shortcut, the way
/// Windows' Win+1..9 focuses the Nth taskbar item. Off by default since it
/// claims nine shortcuts; turn it on in Settings.
public final class DockNumberSwitchModule: FeatureModule {
    private static let numbers: [(n: Int, keyCode: Int)] = [
        (1, kVK_ANSI_1), (2, kVK_ANSI_2), (3, kVK_ANSI_3), (4, kVK_ANSI_4), (5, kVK_ANSI_5),
        (6, kVK_ANSI_6), (7, kVK_ANSI_7), (8, kVK_ANSI_8), (9, kVK_ANSI_9),
    ]
    private static let defaultModifiers = UInt32(controlKey | optionKey)

    public let metadata = ModuleMetadata(
        id: "dock-number-switch",
        displayName: "Switch by Dock Number",
        category: "Dock",
        summary: "Jump to an app by its spot in the Dock with a keyboard shortcut, like Windows' Win plus a number.",
        howToUse: "Press a number shortcut below to focus that app's spot in the Dock, counting from the left (or top, for a side Dock). The first shortcut jumps to the first app in your Dock, and so on. If that app isn't running yet, it launches.",
        requiredPermissions: [.accessibility],
        hotkeys: DockNumberSwitchModule.numbers.map { entry in
            HotkeyAction(
                id: "dock-number-switch.\(entry.n)",
                title: "Focus Dock app \(entry.n)",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(entry.keyCode),
                    carbonModifiers: DockNumberSwitchModule.defaultModifiers
                )
            )
        },
        enabledByDefault: false
    )

    private var tokens: [HotkeyBindings.BindingToken] = []
    private weak var bindings: HotkeyBindings?
    private weak var dock: DockModel?

    public init() {}

    public func start(context: ModuleContext) {
        bindings = context.hotkeyBindings
        dock = context.dock
        for entry in Self.numbers {
            let index = entry.n - 1
            if let token = context.hotkeyBindings.bind("dock-number-switch.\(entry.n)", handler: { [weak self] in
                self?.focus(index: index)
            }) {
                tokens.append(token)
            }
        }
    }

    public func stop() {
        for token in tokens { bindings?.unbind(token) }
        tokens.removeAll()
    }

    /// Activate (or launch) the application Dock item at `index` in Dock order.
    private func focus(index: Int) {
        guard let dock else { return }
        let apps = dock.applicationItems()
        guard apps.indices.contains(index) else { return }
        let item = apps[index]
        if let app = dock.runningApplication(for: item) {
            app.activate()
        } else if let url = item.bundleURL {
            NSWorkspace.shared.open(url)
        }
    }
}
