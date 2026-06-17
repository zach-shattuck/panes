import AppKit

/// Correctly repositions another app's window via Accessibility. Lives in
/// core because multiple features move windows: drag-to-snap, Win+Arrow
/// keyboard snapping, and snap-group restore.
@MainActor
public enum WindowMover {
    /// "AXEnhancedUserInterface" — apps that enable it (Chrome, Electron,
    /// some Java apps) animate/veto AX position changes, producing windows
    /// that land hundreds of points off-target. The reliable recipe is:
    /// turn it off on the app element, move, turn it back on.
    private static let enhancedUIKey = "AXEnhancedUserInterface"

    /// Move + resize a window to an AppKit-space rect (bottom-left origin).
    public static func move(_ window: AXWindow, toAppKitRect rect: NSRect) {
        let cgRect = ScreenGeometry.cgRect(fromAppKit: rect)
        let app = AXElement.application(pid: window.pid)

        let wasEnhanced = app.bool(enhancedUIKey) ?? false
        if wasEnhanced {
            app.set(enhancedUIKey, bool: false)
        }
        window.setFrame(cgRect)
        if wasEnhanced {
            app.set(enhancedUIKey, bool: true)
        }
    }

    /// The screen a window currently sits on (by max overlap), so "left half"
    /// resolves against the display the window is actually on.
    public static func screen(for window: AXWindow) -> NSScreen? {
        guard let cgFrame = window.frame else { return NSScreen.main }
        let appKitFrame = ScreenGeometry.appKitRect(fromCG: cgFrame)
        return NSScreen.screens.max { a, b in
            a.frame.intersection(appKitFrame).area < b.frame.intersection(appKitFrame).area
        } ?? NSScreen.main
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}
