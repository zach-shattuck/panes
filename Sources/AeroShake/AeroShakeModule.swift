import AppKit
import PanesCore
import os

/// Aero Shake: grab a window's title bar and shake it side-to-side to
/// minimize every OTHER window; shake again to bring them back.
///
/// Rides the same passive (non-consuming) drag stream as window snapping —
/// EventTapHub fans one NSEvent monitor out to both. The dragged window is
/// resolved once when a drag begins; per-event work is just direction-reversal
/// bookkeeping, so this is cheap enough to sit on every mouse drag.
public final class AeroShakeModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "aero-shake",
        displayName: "Shake to Minimize",
        category: "Window Management",
        summary: "Grab a window and shake it to minimize everything else, then shake again to bring it all back.",
        howToUse: "Click and hold a window's title bar, then quickly shake your mouse left and right a few times. Every other window minimizes. Shake again to bring them back.",
        requiredPermissions: [.accessibility]
    )

    // Reversal detector tuning.
    private static let minStep: CGFloat = 6        // ignore jitter below this
    private static let reversalsToTrigger = 4      // direction flips…
    private static let windowSeconds = 1.0         // …within this long
    private static let dragThreshold: CGFloat = 8

    private enum DragState {
        case idle
        case pending(downPoint: CGPoint)
        case tracking(window: AXWindow)
        case ignored
    }

    private var state: DragState = .idle
    private var lastX: CGFloat = 0
    private var lastSign: Int = 0
    private var reversals: [ContinuousClock.Instant] = []
    private var didShakeThisDrag = false

    /// What we minimized, so the next shake restores exactly those.
    private var minimizedByShake: [AXWindow] = []

    private var tapToken: EventTapHub.Token?
    private weak var eventTaps: EventTapHub?
    private weak var context: ModuleContext?
    private let log = Logger.panes("aero-shake")

    public init() {}

    public func start(context: ModuleContext) {
        eventTaps = context.eventTaps
        self.context = context
        tapToken = context.eventTaps.subscribe(
            to: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] type, event in
            self?.handle(type: type, event: event)
            return .pass
        }
    }

    public func stop() {
        if let token = tapToken { eventTaps?.unsubscribe(token) }
        tapToken = nil
        // Disabling the feature shouldn't strand windows the user shook away —
        // bring them back. On app quit, leave them (don't un-minimize on every
        // quit), matching how the other side-effecting modules behave.
        if context?.isTerminating != true {
            for window in minimizedByShake { window.setMinimized(false) }
        }
        minimizedByShake.removeAll()
        state = .idle
        reversals.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let point = event.location
        switch type {
        case .leftMouseDown:
            state = .pending(downPoint: point)
            lastX = point.x
            lastSign = 0
            reversals.removeAll()
            didShakeThisDrag = false

        case .leftMouseDragged:
            switch state {
            case .pending(let down):
                let dist = abs(point.x - down.x) + abs(point.y - down.y)
                if dist > Self.dragThreshold {
                    state = resolveDraggedWindow(at: down)
                }
            case .tracking(let window):
                trackReversal(x: point.x, draggedWindow: window)
            case .idle, .ignored:
                break
            }

        case .leftMouseUp:
            state = .idle
            reversals.removeAll()

        default:
            break
        }
    }

    private func resolveDraggedWindow(at downPoint: CGPoint) -> DragState {
        guard
            let window = AXWindow.window(atCGPoint: downPoint),
            window.pid != ProcessInfo.processInfo.processIdentifier,
            window.isStandard
        else { return .ignored }
        return .tracking(window: window)
    }

    private func trackReversal(x: CGFloat, draggedWindow: AXWindow) {
        let dx = x - lastX
        guard abs(dx) >= Self.minStep else { return }
        let sign = dx > 0 ? 1 : -1
        lastX = x

        if lastSign != 0, sign != lastSign {
            let now = ContinuousClock.now
            reversals.append(now)
            reversals.removeAll { now - $0 > .seconds(Self.windowSeconds) }
            if reversals.count >= Self.reversalsToTrigger, !didShakeThisDrag {
                didShakeThisDrag = true
                reversals.removeAll()
                triggerShake(excluding: draggedWindow)
            }
        }
        lastSign = sign
    }

    private func triggerShake(excluding dragged: AXWindow) {
        if !minimizedByShake.isEmpty {
            // Second shake: restore what we hid.
            log.debug("aero shake: restoring \(self.minimizedByShake.count) windows")
            for window in minimizedByShake {
                window.setMinimized(false)
            }
            minimizedByShake.removeAll()
            return
        }

        var minimized: [AXWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.processIdentifier == dragged.pid { continue }
            for window in AXWindow.windows(of: app.processIdentifier)
            where window.isStandard && !window.isMinimized {
                window.setMinimized(true)
                minimized.append(window)
            }
        }
        log.debug("aero shake: minimized \(minimized.count) windows")
        minimizedByShake = minimized
    }
}
