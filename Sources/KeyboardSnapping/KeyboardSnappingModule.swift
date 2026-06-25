import AppKit
import Carbon.HIToolbox
import PanesCore

/// Keyboard window snapping. Uses Ctrl+Option+Arrow rather than Cmd+Arrow,
/// which collides with system and app shortcuts (back/forward, line
/// navigation). Acts on the focused window of the frontmost app and reuses
/// the shared `WindowMover`.
///
/// Left/Right cycle on repeat: tap once for that half, again for a third, again
/// for two-thirds, then back to the half. Up maximizes, Down centers.
public final class KeyboardSnappingModule: FeatureModule {
    private enum Action { case cycleLeft, cycleRight, maximize, center }
    private enum Direction { case left, right }

    /// One snap shortcut: its action id, label, default key, and what it does.
    private struct Binding {
        let id: String
        let title: String
        let keyCode: Int
        let action: Action
    }

    private static let snapBindings: [Binding] = [
        Binding(id: "keyboard-snapping.leftHalf", title: "Snap left", keyCode: kVK_LeftArrow, action: .cycleLeft),
        Binding(id: "keyboard-snapping.rightHalf", title: "Snap right", keyCode: kVK_RightArrow, action: .cycleRight),
        Binding(id: "keyboard-snapping.maximize", title: "Maximize", keyCode: kVK_UpArrow, action: .maximize),
        Binding(id: "keyboard-snapping.center", title: "Center", keyCode: kVK_DownArrow, action: .center),
    ]

    private static let defaultModifiers = UInt32(controlKey | optionKey)

    public let metadata = ModuleMetadata(
        id: "keyboard-snapping",
        displayName: "Keyboard Snapping",
        category: "Snapping",
        summary: "Snap the window you're using with keyboard shortcuts, no dragging needed.",
        howToUse: "Tap the left or right shortcut below to snap the window to that half. Tap the same one again and it cycles to a third, then two-thirds, then back to the half, so you can size it without dragging. Up maximizes and Down centers. If another app already uses one of these, change it here or turn it off there.",
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
        case leftHalf, leftThird, leftTwoThirds
        case rightHalf, rightThird, rightTwoThirds
        case maximize, center

        /// Resolve to an AppKit rect within a screen's usable area.
        func frame(in screen: NSScreen) -> NSRect {
            let a = screen.visibleFrame
            switch self {
            case .leftHalf:        return NSRect(x: a.minX, y: a.minY, width: a.width / 2, height: a.height)
            case .leftThird:       return NSRect(x: a.minX, y: a.minY, width: a.width / 3, height: a.height)
            case .leftTwoThirds:   return NSRect(x: a.minX, y: a.minY, width: a.width * 2 / 3, height: a.height)
            case .rightHalf:       return NSRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height)
            case .rightThird:      return NSRect(x: a.maxX - a.width / 3, y: a.minY, width: a.width / 3, height: a.height)
            case .rightTwoThirds:  return NSRect(x: a.minX + a.width / 3, y: a.minY, width: a.width * 2 / 3, height: a.height)
            case .maximize:        return a
            case .center:
                let size = NSSize(width: a.width * 0.6, height: a.height * 0.75)
                return NSRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
            }
        }
    }

    private static let leftCycle: [Zone] = [.leftHalf, .leftThird, .leftTwoThirds]
    private static let rightCycle: [Zone] = [.rightHalf, .rightThird, .rightTwoThirds]

    /// Where the window was last left by a cycle, so a repeated press advances
    /// instead of restarting (and only if the window is still where we put it).
    private struct CycleState {
        let direction: Direction
        let index: Int
        let frame: NSRect
        let pid: pid_t
        let at: ContinuousClock.Instant
    }
    private var cycleState: CycleState?

    private var tokens: [HotkeyBindings.BindingToken] = []
    private weak var bindings: HotkeyBindings?

    public init() {}

    public func start(context: ModuleContext) {
        bindings = context.hotkeyBindings
        for binding in Self.snapBindings {
            let action = binding.action
            if let token = context.hotkeyBindings.bind(binding.id, handler: { [weak self] in
                self?.perform(action)
            }) {
                tokens.append(token)
            }
        }
    }

    public func stop() {
        for token in tokens { bindings?.unbind(token) }
        tokens.removeAll()
        cycleState = nil
    }

    private func perform(_ action: Action) {
        switch action {
        case .cycleLeft: cycle(.left)
        case .cycleRight: cycle(.right)
        case .maximize: snap(to: .maximize)
        case .center: snap(to: .center)
        }
    }

    private func focusedWindow() -> AXWindow? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let window = AXWindow.focusedWindow(of: app),
            window.isStandard
        else { return nil }
        return window
    }

    private func snap(to zone: Zone) {
        guard let window = focusedWindow(), let screen = WindowMover.screen(for: window) else { return }
        WindowMover.move(window, toAppKitRect: zone.frame(in: screen))
        cycleState = nil
    }

    /// Snap left/right, advancing half → third → two-thirds on repeated taps.
    private func cycle(_ direction: Direction) {
        guard
            let window = focusedWindow(),
            let screen = WindowMover.screen(for: window),
            let currentCG = window.frame
        else { return }
        let current = ScreenGeometry.appKitRect(fromCG: currentCG)
        let zones = direction == .left ? Self.leftCycle : Self.rightCycle

        var index = 0
        if let state = cycleState,
           state.direction == direction,
           state.pid == window.pid,
           ContinuousClock.now - state.at < .seconds(3),
           Self.framesMatch(current, state.frame) {
            index = (state.index + 1) % zones.count
        }

        let target = zones[index].frame(in: screen)
        WindowMover.move(window, toAppKitRect: target)
        cycleState = CycleState(direction: direction, index: index, frame: target, pid: window.pid, at: ContinuousClock.now)
    }

    /// True if the window is still (about) where the last cycle put it; a manual
    /// move or resize since then restarts the cycle at the half.
    private static func framesMatch(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 8) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
