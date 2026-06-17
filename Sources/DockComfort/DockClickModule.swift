import AppKit
import PanesCore
import os

/// Windows-taskbar Dock behavior:
///  - click the FRONTMOST app's icon  -> minimize all its windows
///  - click an app whose windows are all minimized -> restore them
///  - anything else -> let the Dock do its native thing
///
/// Interception requires an ACTIVE event tap (passive monitors observe after
/// delivery — by then the Dock has already acted and may, e.g., trigger App
/// Exposé or de-minimize windows, racing our AX calls). The tap is shared via
/// EventTapHub; this module's subscription is the only thing that forces the
/// hub's consuming tap to exist.
///
/// Hot-path discipline: this handler sits in the delivery path of EVERY left
/// mouse click system-wide, so the not-in-dock exit is two cached rect
/// compares. AX work happens only for clicks physically inside the Dock.
public final class DockClickModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "dock-click-minimize",
        displayName: "Click Dock Icon to Minimize",
        category: "Dock",
        summary: "Click the Dock icon of the app you're using to minimize it, then click the same icon again to bring it back.",
        howToUse: "Click the Dock icon of the app you're currently using and its windows minimize. Click the same icon again to bring them back.",
        requiredPermissions: [.accessibility]
    )

    private var tapToken: EventTapHub.Token?
    private weak var eventTaps: EventTapHub?
    private var dock: DockModel?
    /// Windows we minimized per pid, so restore brings back exactly what the
    /// user hid (not windows the app minimized on its own).
    private var restoreLedger: [pid_t: [AXWindow]] = [:]
    private let log = Logger.panes("dock-click")

    public init() {}

    public func start(context: ModuleContext) {
        dock = context.dock
        eventTaps = context.eventTaps
        tapToken = context.eventTaps.subscribe(
            to: [.leftMouseDown],
            wantsConsume: true
        ) { [weak self] _, event in
            self?.handleClick(event) ?? .pass
        }
    }

    public func stop() {
        if let token = tapToken { eventTaps?.unsubscribe(token) }
        tapToken = nil
        dock = nil
        restoreLedger.removeAll()
    }

    private func handleClick(_ event: CGEvent) -> EventTapHub.Verdict {
        guard let dock else { return .pass }

        // A Dock preview is steering a window selection by scroll — let its
        // click commit the highlighted window instead of minimizing here.
        guard !dock.suppressClickMinimize else { return .pass }

        // Modifier clicks keep native semantics (Cmd-click reveals in
        // Finder, Option-click hides others, etc.).
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard modifiers.isEmpty else { return .pass }

        // Fast path: one cached-rect compare for every click in the system.
        // The inset absorbs dock magnification growth (frames are cached up
        // to 2 s); the AX item hit test below stays exact.
        let point = event.location
        guard let dockFrame = dock.dockFrame(),
              dockFrame.insetBy(dx: -64, dy: -96).contains(point) else { return .pass }

        guard
            let item = dock.item(atCGPoint: point),
            item.isApplication,
            item.isRunning,
            let app = dock.runningApplication(for: item)
        else { return .pass }

        let pid = app.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            // Clicking the ACTIVE app's icon always does something (minimize its
            // visible windows, or restore if they're all hidden). Decide consume
            // immediately and do the AX work off the hot path so a slow app can
            // never delay the click or trip the tap timeout.
            performToggle(pid: pid, app: app)
            return .consume
        }

        // Non-frontmost icon: we only intercept the "all windows minimized ->
        // restore" case. Resolve it with a TIME-BOUNDED enumeration so a wedged
        // app can't stall the click; otherwise let the Dock do its native thing.
        let windows = AXWindow.windows(of: pid, timeout: 0.3).filter(\.isStandard)
        guard !windows.isEmpty, windows.allSatisfy(\.isMinimized) else { return .pass }
        performToggle(pid: pid, app: app)
        return .consume
    }

    /// Off the event hot path (next runloop): re-read the app's windows and
    /// minimize the visible ones, or restore if they're all hidden. Keeping the
    /// AX latency out of the tap callback is what stops clicks from lagging.
    private func performToggle(pid: pid_t, app: NSRunningApplication) {
        Task { [weak self] in
            guard let self else { return }
            let windows = AXWindow.windows(of: pid, timeout: 0.5).filter(\.isStandard)
            guard !windows.isEmpty else { return }
            let visible = windows.filter { !$0.isMinimized }
            if !visible.isEmpty {
                self.log.debug("minimizing \(visible.count) windows of pid \(pid)")
                for window in visible { window.setMinimized(true) }
                self.restoreLedger[pid] = visible
            } else {
                let toRestore = self.restoreLedger[pid] ?? windows
                self.log.debug("restoring \(toRestore.count) windows of pid \(pid)")
                for window in toRestore { window.setMinimized(false) }
                self.restoreLedger[pid] = nil
                toRestore.last?.raise()
                app.activate()
            }
        }
    }
}
