import AppKit
import PanesCore
import os

/// Windows-taskbar Dock behavior:
///  - click the FRONTMOST app's icon  -> minimize all its windows
///  - click an app whose windows are all minimized -> restore them
///  - anything else -> let the Dock do its native thing
///
/// Click vs. drag: we must NOT swallow the mouse-PRESS, or the Dock can never
/// start a drag and reordering icons breaks (the press turns into a click).
/// So we let the press through, remember it, and act on the mouse-UP — and only
/// if the cursor barely moved (a real click). If it moved, it was a drag (icon
/// reorder or removal) and we stay out of the way entirely.
///
/// Acting on the up (not the down) also means the Dock's native click handler
/// fires on the same up, so for the cases we handle we CONSUME the up to
/// suppress it. The tap is shared via EventTapHub.
///
/// Hot-path discipline: this sits in the delivery path of every left click, so
/// the not-in-dock exit is a couple of cached-rect compares; AX work happens
/// only for a stationary click physically inside the Dock.
public final class DockClickModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "dock-click-minimize",
        displayName: "Click Dock Icon to Minimize",
        category: "Dock",
        summary: "Click the Dock icon of the app you're using to minimize it, then click the same icon again to bring it back.",
        howToUse: "Click the Dock icon of the app you're currently using and its windows minimize. Click the same icon again to bring them back. Dragging icons to rearrange your Dock still works as normal.",
        requiredPermissions: [.accessibility]
    )

    /// A press on a Dock app icon, pending its release to decide click vs drag.
    private struct PendingClick {
        let downPoint: CGPoint
        let pid: pid_t
        let app: NSRunningApplication
        let frontmost: Bool
    }

    /// How far the cursor may move between press and release and still count as
    /// a click rather than a drag.
    private static let clickSlop: CGFloat = 6

    private var pending: PendingClick?
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
            to: [.leftMouseDown, .leftMouseUp],
            wantsConsume: true
        ) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    public func stop() {
        if let token = tapToken { eventTaps?.unsubscribe(token) }
        tapToken = nil
        pending = nil
        dock = nil
        restoreLedger.removeAll()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> EventTapHub.Verdict {
        switch type {
        case .leftMouseDown:
            pending = recordPress(event)
            return .pass // never swallow the press, so the Dock can start a drag
        case .leftMouseUp:
            return handleRelease(event)
        default:
            return .pass
        }
    }

    /// Note a press on a Dock app icon (or nil if it's not one we'd act on).
    private func recordPress(_ event: CGEvent) -> PendingClick? {
        guard let dock else { return nil }

        // A Dock preview is steering a window selection by scroll — let its
        // click commit the highlighted window instead of minimizing here.
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

        guard
            let item = dock.item(atCGPoint: point),
            item.isApplication,
            item.isRunning,
            let app = dock.runningApplication(for: item)
        else { return nil }

        let pid = app.processIdentifier
        return PendingClick(
            downPoint: point,
            pid: pid,
            app: app,
            frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        )
    }

    private func handleRelease(_ event: CGEvent) -> EventTapHub.Verdict {
        guard let press = pending else { return .pass }
        pending = nil

        // A drag (reorder / remove) moves the cursor; only a near-stationary
        // press-release is a click.
        let up = event.location
        let moved = abs(up.x - press.downPoint.x) + abs(up.y - press.downPoint.y)
        guard moved <= Self.clickSlop else { return .pass }

        if press.frontmost {
            // The active app's icon: minimize its visible windows (or restore if
            // they're all hidden). Decide consume now; do the AX work off the
            // hot path so a slow app can't stall the click.
            performToggle(pid: press.pid, app: press.app)
            return .consume
        }

        // Non-frontmost: only intercept the "all windows minimized -> restore"
        // case. Time-bounded so a wedged app can't stall the release; otherwise
        // let the Dock do its native thing.
        let windows = AXWindow.windows(of: press.pid, timeout: 0.25).filter(\.isStandard)
        guard !windows.isEmpty, windows.allSatisfy(\.isMinimized) else { return .pass }
        performToggle(pid: press.pid, app: press.app)
        return .consume
    }

    /// Off the event hot path (next runloop): re-read the app's windows and
    /// minimize the visible ones, or restore if they're all hidden.
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
