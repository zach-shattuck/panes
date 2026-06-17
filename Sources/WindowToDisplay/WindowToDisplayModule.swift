import AppKit
import Carbon.HIToolbox
import PanesCore

/// Move the focused window to the next/previous display with a keyboard
/// shortcut (Windows' Win+Shift+Arrow). The window keeps its relative position
/// and size, so a left-half window stays left-half on the new screen and a
/// centered one stays centered.
public final class WindowToDisplayModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "window-to-display",
        displayName: "Move to Display",
        category: "Window Management",
        summary: "Send the window you're using to your next monitor with a keyboard shortcut, keeping its place and size.",
        howToUse: "With more than one display connected, use the shortcuts below to move the focused window to the next or previous monitor. It keeps the same relative position and size on the new screen. With a single display these do nothing.",
        requiredPermissions: [.accessibility],
        hotkeys: [
            HotkeyAction(
                id: "window-to-display.next",
                title: "Move to next display",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(kVK_RightArrow),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
                )
            ),
            HotkeyAction(
                id: "window-to-display.previous",
                title: "Move to previous display",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(kVK_LeftArrow),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
                )
            ),
        ]
    )

    private var tokens: [HotkeyBindings.BindingToken] = []
    private weak var bindings: HotkeyBindings?

    public init() {}

    public func start(context: ModuleContext) {
        bindings = context.hotkeyBindings
        if let token = context.hotkeyBindings.bind("window-to-display.next", handler: { [weak self] in
            self?.move(toNext: true)
        }) { tokens.append(token) }
        if let token = context.hotkeyBindings.bind("window-to-display.previous", handler: { [weak self] in
            self?.move(toNext: false)
        }) { tokens.append(token) }
    }

    public func stop() {
        for token in tokens { bindings?.unbind(token) }
        tokens.removeAll()
    }

    private func move(toNext: Bool) {
        let screens = NSScreen.screens
        guard screens.count > 1,
              let app = NSWorkspace.shared.frontmostApplication,
              let window = AXWindow.focusedWindow(of: app),
              window.isStandard,
              let cg = window.frame
        else { return }

        let appKit = ScreenGeometry.appKitRect(fromCG: cg)
        let center = CGPoint(x: appKit.midX, y: appKit.midY)
        // The window's current screen: the one under its center, else the one
        // it overlaps most.
        guard let currentIndex = screens.firstIndex(where: { $0.frame.contains(center) })
            ?? screens.firstIndex(where: { $0.frame.intersects(appKit) })
        else { return }

        let target = screens[(currentIndex + (toNext ? 1 : -1) + screens.count) % screens.count]
        let from = screens[currentIndex].visibleFrame
        let to = target.visibleFrame
        guard from.width > 0, from.height > 0 else { return }

        // Map the frame proportionally into the target's usable area.
        let moved = NSRect(
            x: to.minX + (appKit.minX - from.minX) / from.width * to.width,
            y: to.minY + (appKit.minY - from.minY) / from.height * to.height,
            width: appKit.width / from.width * to.width,
            height: appKit.height / from.height * to.height
        )
        WindowMover.move(window, toAppKitRect: moved)
    }
}
