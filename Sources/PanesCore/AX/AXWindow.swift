import AppKit
import ApplicationServices
import os

/// A window of (usually) another application, manipulated via Accessibility.
@MainActor
public struct AXWindow {
    public let element: AXElement
    public let pid: pid_t

    /// Every window mutation Panes performs is logged here at `.notice` (which
    /// persists), so any "who minimized my windows?" incident can be traced to
    /// the exact action and time via:
    ///   log show --predicate 'subsystem == "dev.panes.app" AND category == "window-actions"' --last 20m
    private static let actionLog = Logger.panes("window-actions")

    private func appName() -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    public init(element: AXElement, pid: pid_t) {
        self.element = element
        self.pid = pid
    }

    // MARK: Discovery

    /// The window under a point (CG top-left coordinates), resolved via the
    /// system-wide element and walking up to the containing AXWindow.
    public static func window(atCGPoint point: CGPoint) -> AXWindow? {
        guard var element = AXElement.systemWide.elementAtPosition(point) else { return nil }
        var hops = 0
        while element.role != kAXWindowRole {
            guard let parent = element.parent, hops < 25 else { return nil }
            element = parent
            hops += 1
        }
        guard let pid = element.pid else { return nil }
        return AXWindow(element: element, pid: pid)
    }

    public static func focusedWindow(of app: NSRunningApplication) -> AXWindow? {
        let appElement = AXElement.application(pid: app.processIdentifier)
        guard let window = appElement.element(kAXFocusedWindowAttribute) else { return nil }
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    /// `timeout` (seconds) bounds the AX round trip so a wedged or slow app
    /// (Chromium-based browsers especially) can't hang the caller — important on
    /// the event-tap hot path, where a stall trips the tap's own timeout.
    public static func windows(of pid: pid_t, timeout: Float? = nil) -> [AXWindow] {
        let app = AXElement.application(pid: pid)
        if let timeout { AXUIElementSetMessagingTimeout(app.raw, timeout) }
        return app.elements(kAXWindowsAttribute).map { AXWindow(element: $0, pid: pid) }
    }

    // MARK: Attributes

    public var title: String? { element.title }

    public var isMinimized: Bool {
        element.bool(kAXMinimizedAttribute) ?? false
    }

    /// Frame in CG top-left global coordinates.
    public var frame: CGRect? { element.frame }

    public var subrole: String? { element.subrole }

    /// Standard windows only — skips sheets, drawers, and panels so window
    /// management never resizes a Save dialog.
    public var isStandard: Bool {
        subrole == kAXStandardWindowSubrole
    }

    // MARK: Mutation

    /// Sets the frame (CG top-left coordinates) as size → position → size,
    /// the empirically reliable order: AX only allows size and
    /// position individually, and macOS clamps each against the CURRENT
    /// display, so moving across displays needs the size re-applied after
    /// the position lands on the destination screen.
    public func setFrame(_ rect: CGRect) {
        Self.actionLog.notice("move \(self.appName(), privacy: .public) to \(Int(rect.minX))·\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))")
        element.set(kAXSizeAttribute, size: rect.size)
        element.set(kAXPositionAttribute, point: rect.origin)
        element.set(kAXSizeAttribute, size: rect.size)
    }

    public func setMinimized(_ minimized: Bool) {
        Self.actionLog.notice("\(minimized ? "MINIMIZE" : "unminimize", privacy: .public) \(self.appName(), privacy: .public)")
        if minimized, let button = element.element(kAXMinimizeButtonAttribute) {
            // Press the actual minimize button. Some apps (Chromium browsers
            // like Edge and Chrome) silently ignore the minimized attribute
            // setter but do respond to the button. Restoring still uses the
            // attribute, since a minimized window has no button to press.
            button.perform(kAXPressAction)
        } else {
            element.set(kAXMinimizedAttribute, bool: minimized)
        }
    }

    /// macOS native full-screen. "AXFullScreen" is a settable attribute on
    /// standard windows (it's what the green traffic-light button drives).
    private static let fullScreenAttribute = "AXFullScreen"

    public var isFullScreen: Bool {
        element.bool(Self.fullScreenAttribute) ?? false
    }

    public func toggleFullScreen() {
        Self.actionLog.notice("toggleFullScreen \(self.appName(), privacy: .public)")
        element.set(Self.fullScreenAttribute, bool: !isFullScreen)
    }

    /// Brings the window above all others: activate the owning app, then
    /// raise this specific window within it and mark it the main window. All
    /// three are needed — activation alone may front a different window of
    /// that app, AXRaise alone only reorders within the app.
    public func raise() {
        Self.actionLog.notice("RAISE/activate \(self.appName(), privacy: .public)")
        NSRunningApplication(processIdentifier: pid)?.activate()
        element.perform(kAXRaiseAction)
        element.set(kAXMainAttribute, bool: true)
    }

    public func close() {
        Self.actionLog.notice("CLOSE \(self.appName(), privacy: .public)")
        element.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }
}
