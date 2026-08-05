import AppKit
import PanesCore
import os

/// Windows-taskbar Dock behavior:
///  - click the FRONTMOST app's icon  -> minimize all its windows
///  - click an app whose windows are all minimized -> restore them
///  - anything else -> let the Dock do its native thing
///
/// We never consume Dock mouse events. We only OBSERVE them and perform the
/// minimize/restore ourselves. Consuming caused two bugs: swallowing the press
/// broke dragging icons to reorder, and swallowing the release left the Dock
/// thinking the button was still held (no matching up), which it then treated
/// as a press-and-hold and opened the icon's context menu (a phantom
/// "right-click"). Observing-only leaves clicks, drags, and the long-press menu
/// all behaving natively.
///
/// A "click" here is a press and release that is both QUICK and nearly
/// stationary. A press that moves is a drag (reorder/remove); a press that's
/// held is a long-press for the context menu — we act on neither.
///
/// Hot-path discipline: this sees every left click, so the not-in-dock exit is
/// a couple of cached-rect compares; AX work happens only for a real click
/// physically inside the Dock.
public final class DockClickModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "dock-click-minimize",
        displayName: "Click Dock Icon to Minimize",
        category: "Dock",
        summary: "Click the Dock icon of the app you're using to minimize it, then click the same icon again to bring it back.",
        howToUse: "Click the Dock icon of the app you're currently using and its windows minimize. Click the same icon again to bring them back. Dragging icons to rearrange your Dock works as normal.",
        requiredPermissions: [.accessibility]
    )

    /// A press on a Dock app icon, pending its release to decide click vs drag
    /// vs long-press.
    private struct PendingPress {
        let downPoint: CGPoint
        let at: ContinuousClock.Instant
        let pid: pid_t
        let app: NSRunningApplication
        let frontmost: Bool
    }

    /// A click may move at most this far and be held at most this long; beyond
    /// either it's a drag or a long-press, which we leave to the Dock.
    private static let clickSlop: CGFloat = 6
    private static let maxClickDuration: Duration = .milliseconds(500)

    private var pending: PendingPress?
    private var downToken: EventTapHub.Token?
    private var upToken: EventTapHub.Token?
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
        // The PRESS rides the consuming tap (wantsConsume: true) purely for
        // SYNCHRONOUS delivery — the tap sees the event before the Dock does, so
        // we read the frontmost app BEFORE the Dock activates the clicked icon.
        // Without this, clicking a background app to bring it forward would look
        // "already frontmost" and we'd wrongly minimize it. We still never
        // consume (always .pass), so clicks, drags, and the menu stay native.
        downToken = context.eventTaps.subscribe(
            to: [.leftMouseDown],
            wantsConsume: true
        ) { [weak self] _, event in
            guard let self else { return .pass }
            self.pending = self.recordPress(event)
            return .pass
        }
        // The RELEASE only acts (the decision was made at press), so its timing
        // doesn't matter — keep it observe-only off the consuming tap.
        upToken = context.eventTaps.subscribe(
            to: [.leftMouseUp]
        ) { [weak self] _, event in
            self?.handleRelease(event)
            return .pass
        }
    }

    public func stop() {
        if let token = downToken { eventTaps?.unsubscribe(token) }
        if let token = upToken { eventTaps?.unsubscribe(token) }
        downToken = nil
        upToken = nil
        pending = nil
        dock = nil
        restoreLedger.removeAll()
    }

    /// Note a press on a Dock app icon (or nil if it's not one we'd act on).
    private func recordPress(_ event: CGEvent) -> PendingPress? {
        guard let dock else { return nil }

        // A Dock preview is steering a window selection by scroll — leave the
        // click to it.
        guard !dock.suppressClickMinimize else { return nil }

        // Modifier clicks keep native semantics (Cmd-click reveals in Finder,
        // Option-click hides others, etc.).
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard modifiers.isEmpty else { return nil }

        // Fast path: cached-rect compare. The inset absorbs dock magnification;
        // the AX item hit test stays exact.
        let point = event.location
        guard let dockFrame = dock.dockFrame(),
              dockFrame.insetBy(dx: -64, dy: -96).contains(point) else { return nil }

        guard let item = dock.item(atCGPoint: point), item.isApplication else { return nil }
        guard item.isRunning, let app = dock.runningApplication(for: item) else {
            log.notice("dock: app icon '\(item.title ?? "?", privacy: .public)' clicked but not resolved to a running app (running=\(item.isRunning, privacy: .public))")
            return nil
        }

        let pid = app.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return PendingPress(downPoint: point, at: ContinuousClock.now, pid: pid, app: app, frontmost: frontmost)
    }

    private func handleRelease(_ event: CGEvent) {
        guard let press = pending else { return }
        pending = nil

        // Drag (reorder/remove) moves the cursor; long-press (context menu) is
        // held. A click is neither.
        let up = event.location
        let moved = abs(up.x - press.downPoint.x) + abs(up.y - press.downPoint.y)
        let name = press.app.localizedName ?? "pid \(press.pid)"
        let held = ContinuousClock.now - press.at
        guard moved <= Self.clickSlop, held <= Self.maxClickDuration else {
            log.notice("dock release: \(name, privacy: .public) IGNORED as drag/hold (moved=\(Int(moved), privacy: .public)pt, held=\("\(held)", privacy: .public))")
            return
        }

        if press.frontmost {
            // The active app's icon: clicking it does nothing natively, so we
            // just minimize (or restore if its windows are already hidden).
            log.notice("dock release: \(name, privacy: .public) → MINIMIZE (was frontmost)")
            performToggle(pid: press.pid, app: press.app)
            return
        }

        // Non-frontmost: only handle the "all windows minimized -> restore"
        // case. Time-bounded so a wedged app can't stall us.
        let windows = AXWindow.windows(of: press.pid, timeout: 0.25).filter(\.isStandard)
        guard !windows.isEmpty, windows.allSatisfy(\.isMinimized) else {
            log.notice("dock release: \(name, privacy: .public) → Dock brings it forward (not frontmost; \(windows.count, privacy: .public) windows, not all minimized)")
            return
        }
        log.notice("dock release: \(name, privacy: .public) → RESTORE (all were minimized)")
        performToggle(pid: press.pid, app: press.app)
    }

    /// Off the event path: re-read the app's windows and minimize the visible
    /// ones, or restore if they're all hidden.
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
