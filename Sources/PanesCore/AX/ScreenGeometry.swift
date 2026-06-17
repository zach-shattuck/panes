import AppKit

/// Conversions between the two global coordinate spaces on macOS:
///
///  - AppKit space (NSScreen, NSWindow, NSEvent.mouseLocation): origin at the
///    BOTTOM-left of the primary display, y grows upward.
///  - CG/AX space (CGEvent.location, AXUIElement frames, CGWindowList,
///    ScreenCaptureKit): origin at the TOP-left of the primary display,
///    y grows downward.
///
/// Both spaces flip around the PRIMARY display's height (NSScreen.screens[0],
/// the one with the menu bar), not the height of whichever display contains
/// the rect — getting that wrong only shows up on multi-monitor setups, which
/// is why it's centralized here.
@MainActor
public enum ScreenGeometry {
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    public static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func appKitPoint(fromCG point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func appKitRect(fromCG rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Screen containing a point given in CG top-left coordinates.
    public static func screen(containingCGPoint point: CGPoint) -> NSScreen? {
        let appKitPoint = appKitPoint(fromCG: point)
        return NSScreen.screens.first { $0.frame.contains(appKitPoint) }
    }

    /// The current mouse location in CG top-left coordinates.
    public static var mouseLocationCG: CGPoint {
        cgPoint(fromAppKit: NSEvent.mouseLocation)
    }
}
