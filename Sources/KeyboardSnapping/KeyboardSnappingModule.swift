import AppKit
import Carbon.HIToolbox
import PanesCore

/// Keyboard window snapping. Uses Ctrl+Option+Arrow rather than Cmd+Arrow,
/// which collides with system and app shortcuts (back/forward, line
/// navigation). Acts on the focused window of the frontmost app and reuses
/// the shared `WindowMover`.
public final class KeyboardSnappingModule: FeatureModule {
    /// One snap shortcut: its action id, label, default key, and target zone.
    private struct Binding {
        let id: String
        let title: String
        let keyCode: Int
        let zone: Zone
    }

    private static let snapBindings: [Binding] = [
        Binding(id: "keyboard-snapping.leftHalf", title: "Snap to left half", keyCode: kVK_LeftArrow, zone: .leftHalf),
        Binding(id: "keyboard-snapping.rightHalf", title: "Snap to right half", keyCode: kVK_RightArrow, zone: .rightHalf),
        Binding(id: "keyboard-snapping.maximize", title: "Maximize", keyCode: kVK_UpArrow, zone: .maximize),
        Binding(id: "keyboard-snapping.center", title: "Center", keyCode: kVK_DownArrow, zone: .center),
    ]

    private static let defaultModifiers = UInt32(controlKey | optionKey)

    public let metadata = ModuleMetadata(
        id: "keyboard-snapping",
        displayName: "Keyboard Snapping",
        category: "Snapping",
        summary: "Snap the window you're using with keyboard shortcuts, no dragging needed.",
        howToUse: "Use the shortcuts below to snap the window you're working in to the left half, right half, maximized, or centered. If another app already uses one of them, change it here or turn it off there to avoid conflicts.",
        requiredPermissions: [.accessibility],
        hotkeys: KeyboardSnappingModule.snapBindings.map {
            HotkeyAction(
                id: $0.id,
                title: $0.title,
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32($0.keyCode),
                    carbonModifiers: KeyboardSnappingModule.defaultModifiers
                )
            )
        }
    )

    private enum Zone {
        case leftHalf, rightHalf, maximize, center

        /// Resolve to an AppKit rect within a screen's usable area.
        func frame(in screen: NSScreen) -> NSRect {
            let area = screen.visibleFrame
            switch self {
            case .leftHalf:
                return NSRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
            case .rightHalf:
                return NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
            case .maximize:
                return area
            case .center:
                let size = NSSize(width: area.width * 0.6, height: area.height * 0.75)
                return NSRect(
                    x: area.midX - size.width / 2,
                    y: area.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            }
        }
    }

    private var tokens: [HotkeyBindings.BindingToken] = []
    private weak var bindings: HotkeyBindings?

    public init() {}

    public func start(context: ModuleContext) {
        bindings = context.hotkeyBindings
        for binding in Self.snapBindings {
            let zone = binding.zone
            if let token = context.hotkeyBindings.bind(binding.id, handler: { [weak self] in
                self?.snap(to: zone)
            }) {
                tokens.append(token)
            }
        }
    }

    public func stop() {
        for token in tokens { bindings?.unbind(token) }
        tokens.removeAll()
    }

    private func snap(to zone: Zone) {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let window = AXWindow.focusedWindow(of: app),
            window.isStandard,
            let screen = WindowMover.screen(for: window)
        else { return }
        WindowMover.move(window, toAppKitRect: zone.frame(in: screen))
    }
}
