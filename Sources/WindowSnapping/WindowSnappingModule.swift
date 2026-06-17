import AppKit
import ApplicationServices
import PanesCore
import os

/// Windows-style snap assist: drag a window toward the top-center of a
/// screen and a layout palette drops down; release over a zone to snap the
/// window there.
///
/// Coexistence note: macOS 15+ ships native edge tiling. Its top-edge
/// gesture fires when the cursor PUSHES INTO the menu bar, while our trigger
/// band sits just below it; users who find the two fighting can turn off
/// "Drag windows to screen edges to tile" in System Settings > Desktop &
/// Dock (there is no API to do it for them).
public final class WindowSnappingModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "window-snapping",
        displayName: "Window Snapping",
        category: "Snapping",
        summary: "Drag a window to a screen edge to snap it: the top to maximize, a side for that half, or a corner for a quarter. Drag to the top center to pick from a set of layouts instead.",
        howToUse: "Drag any window by its title bar to an edge of the screen and a preview shows where it will land: the top maximizes it, the left or right edge takes that half, and a corner takes that quarter. Let go to snap it there. Drag to the top center instead to pick from a set of layouts. If a window is already snapped, just drag it and it goes back to its original size.",
        requiredPermissions: [.accessibility],
        options: [
            .toggle(
                key: snapAssistKey,
                title: "Snap Assist",
                detail: "After you snap a window to one half, pick one of your other windows to fill the other half.",
                defaultOn: true
            )
        ]
    )

    static let snapAssistKey = "window-snapping.snapAssist"

    private enum DragState {
        case idle
        /// Mouse is down but we haven't decided whether this is a window drag.
        case pending(downPoint: CGPoint)
        /// Definitely dragging this window.
        case tracking(window: AXWindow)
        /// Mouse is down on something we must not snap (own UI, non-window,
        /// non-standard window) — stay out of the way until mouse up.
        case ignored
    }

    private var state: DragState = .idle
    private var tapToken: EventTapHub.Token?
    private weak var eventTaps: EventTapHub?
    private weak var preferences: PreferencesStore?
    private var palette: SnapOverlayPanel?
    private var paletteScreen: NSScreen?
    /// The layouts shown for the CURRENT drag (presets + custom), captured when
    /// the drag begins so a drop resolves against exactly what was on screen.
    private var dragOptions: [SnapLayoutOption] = SnapLayoutOption.palette
    private let log = Logger.panes("snapping")

    /// Aero-snap: dragging a window to a screen edge or corner snaps it there.
    /// While the cursor is in an edge zone, `preview` highlights the target.
    private var preview: SnapPreviewPanel?
    private var edgeZone: EdgeZone?
    private var edgeScreen: NSScreen?

    /// Delays opening the snap-layouts palette until you've hovered the tab.
    private var expandTimer: Timer?

    /// Snap Assist: after a half-snap, offer the other windows for the empty
    /// half. Reuses the shared enumerator for the list + thumbnails.
    private let enumerator = WindowEnumerator()
    private var assistPanel: SnapAssistPanel?
    private var pendingAssistRect: NSRect?

    /// Records of windows we snapped: the size we snapped them to and the
    /// frame to restore them to. Dragging a window whose size still matches
    /// what we set restores its pre-snap size under the cursor (the Windows
    /// un-snap gesture). Matched by pid + size — not element identity
    /// (AXUIElement equality across separate hit-tests is unreliable) and not
    /// position (the window has already moved a few points by the time we
    /// check); a manual resize since snapping changes the size and so cancels
    /// the revert.
    private struct SnapRecord {
        let pid: pid_t
        let snappedSize: CGSize
        let preSnap: CGRect
    }
    private var snapRecords: [SnapRecord] = []

    /// Drag must travel this far before we pay for AX window resolution.
    private static let dragThreshold: CGFloat = 12

    public init() {}

    public func start(context: ModuleContext) {
        warnIfNativeTilingConflicts()
        palette = SnapOverlayPanel()
        preview = SnapPreviewPanel()
        eventTaps = context.eventTaps
        preferences = context.preferences

        let assist = SnapAssistPanel()
        assist.onChoose = { [weak self] item in self?.fillAssist(with: item) }
        assistPanel = assist
        enumerator.prewarm()
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
        cancelExpand()
        palette?.hide()
        palette = nil
        clearEdgePreview()
        preview = nil
        assistPanel?.hide()
        assistPanel = nil
        pendingAssistRect = nil
        state = .idle
        snapRecords.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let point = event.location
        switch type {
        case .leftMouseDown:
            state = .pending(downPoint: point)

        case .leftMouseDragged:
            switch state {
            case .pending(let downPoint):
                let distance = abs(point.x - downPoint.x) + abs(point.y - downPoint.y)
                guard distance > Self.dragThreshold else { return }
                let resolved = resolveDrag(at: downPoint)
                if case .tracking(let window) = resolved {
                    // Capture the layouts (presets + custom) for this drag and
                    // feed them to the palette so its size and hit-testing match.
                    dragOptions = currentOptions()
                    palette?.setOptions(dragOptions)
                    unsnapIfNeeded(window, cursorCG: point)
                }
                state = resolved
            case .tracking:
                updateDragFeedback(for: point)
            case .idle, .ignored:
                break
            }

        case .leftMouseUp:
            if case .tracking(let window) = state {
                if let ref = palette?.zone(atCGPoint: point), let screen = paletteScreen,
                   dragOptions.indices.contains(ref.option),
                   dragOptions[ref.option].zones.indices.contains(ref.zone) {
                    // Dropped on an expanded snap-layout cell.
                    let option = dragOptions[ref.option]
                    snap(window, toFrame: SnapLayoutOption.frame(for: option.zones[ref.zone], on: screen))
                } else if let screen = ScreenGeometry.screen(containingCGPoint: point),
                          paletteHotRegion(on: screen)?.contains(point) != true,
                          let zone = Self.edgeZone(at: point, on: screen) {
                    // Aero-snap edge/corner. Re-checked at the release point so
                    // a fast slam still snaps even if the last drag event missed.
                    snap(window, toFrame: zone.frame(in: screen))
                }
            }
            cancelExpand()
            palette?.hide()
            paletteScreen = nil
            clearEdgePreview()
            state = .idle

        default:
            break
        }
    }

    /// Built-in presets followed by the user's saved custom layouts.
    private func currentOptions() -> [SnapLayoutOption] {
        let custom = preferences.map { CustomLayoutStore.load($0).map(SnapLayoutOption.init) } ?? []
        return SnapLayoutOption.palette + custom
    }

    /// One-time AX cost per drag, paid only after the movement threshold.
    private func resolveDrag(at downPoint: CGPoint) -> DragState {
        guard
            let window = AXWindow.window(atCGPoint: downPoint),
            window.pid != ProcessInfo.processInfo.processIdentifier,
            window.isStandard,
            let frame = window.frame
        else { return .ignored }

        // Only treat grabs of the title-bar region as window drags —
        // dragging a scrollbar or selecting text must not arm snapping.
        let titleBarRegion = CGRect(
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: 36
        )
        guard titleBarRegion.contains(downPoint) else { return .ignored }
        return .tracking(window: window)
    }

    /// Decides what feedback to show while dragging a window. In the top-center
    /// "hot region" the snap-layouts palette peeks and then expands (Windows 11
    /// style); everywhere else along the edges, Aero-snap previews appear.
    private func updateDragFeedback(for point: CGPoint) {
        guard let palette, let screen = ScreenGeometry.screen(containingCGPoint: point) else {
            palette?.hide(); paletteScreen = nil; clearEdgePreview(); return
        }

        if let hot = paletteHotRegion(on: screen), hot.contains(point) {
            paletteScreen = screen

            if palette.isExpanded {
                palette.highlight(palette.zone(atCGPoint: point))
            } else if palette.tabContains(cgPoint: point, on: screen) {
                // Cursor is directly on the tab: highlight it, then open after a
                // short delay (so it doesn't fly open the instant you touch it).
                palette.peek(on: screen)
                palette.setTabHovered(true)
                scheduleExpand()
            } else {
                // Elsewhere in the hot region: just show the tab.
                cancelExpand()
                palette.peek(on: screen)
                palette.setTabHovered(false)
            }
            clearEdgePreview()
            return
        }

        cancelExpand()
        palette.hide()
        paletteScreen = nil
        updateEdgeSnap(for: point)
    }

    /// Open the palette after a brief hover delay, re-checking that the cursor
    /// is still on the tab when the delay elapses.
    private func scheduleExpand() {
        guard expandTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { _ in
            MainActor.assumeIsolated { SnapModuleHolder.current?.fireExpand() }
        }
        expandTimer = timer
        SnapModuleHolder.current = self
    }

    private func cancelExpand() {
        expandTimer?.invalidate()
        expandTimer = nil
    }

    private func fireExpand() {
        expandTimer = nil
        guard case .tracking = state, let palette, !palette.isExpanded else { return }
        let point = ScreenGeometry.mouseLocationCG
        guard let screen = ScreenGeometry.screen(containingCGPoint: point),
              palette.tabContains(cgPoint: point, on: screen) else {
            palette.setTabHovered(false)
            return
        }
        palette.expand(on: screen)
    }

    /// The region (CG) that keeps the snap-layouts palette engaged: from the
    /// very top of the screen down through the expanded palette, across the
    /// center. Aero-snap edges apply everywhere outside it.
    private func paletteHotRegion(on screen: NSScreen) -> CGRect? {
        guard let palette else { return nil }
        let expanded = ScreenGeometry.cgRect(fromAppKit: palette.expandedFrame(on: screen))
        let screenCG = ScreenGeometry.cgRect(fromAppKit: screen.frame)
        let margin: CGFloat = 52
        return CGRect(
            x: expanded.minX - margin,
            y: screenCG.minY,
            width: expanded.width + margin * 2,
            height: (expanded.maxY - screenCG.minY) + 24
        )
    }

    /// Show the Aero-snap preview if the cursor is in a screen edge or corner
    /// zone, otherwise clear it.
    private func updateEdgeSnap(for point: CGPoint) {
        guard
            let screen = ScreenGeometry.screen(containingCGPoint: point),
            let zone = Self.edgeZone(at: point, on: screen)
        else {
            clearEdgePreview()
            return
        }
        edgeZone = zone
        edgeScreen = screen
        preview?.show(appKitRect: zone.frame(in: screen))
    }

    private func clearEdgePreview() {
        edgeZone = nil
        edgeScreen = nil
        preview?.hide()
    }

    /// The snap zone for a cursor position (CG top-left coords). Corners take
    /// priority over edges so the quarters are reachable.
    private static func edgeZone(at point: CGPoint, on screen: NSScreen) -> EdgeZone? {
        let f = ScreenGeometry.cgRect(fromAppKit: screen.frame)
        // The top zone is about the menu bar's height so you can just shove the
        // cursor up to the top and hit it, rather than aiming at a 1px sliver.
        // Sides/bottom stay a thin strip you push the cursor into.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let topZone = max(menuBar - 1, 22)
        let edge: CGFloat = 8     // how close to the side/bottom edge to trigger
        let corner: CGFloat = 100 // reach of a corner along each edge

        let nearLeft = point.x <= f.minX + edge
        let nearRight = point.x >= f.maxX - edge
        let nearTop = point.y <= f.minY + topZone
        let nearBottom = point.y >= f.maxY - edge

        let topLeft = (nearTop && point.x <= f.minX + corner) || (nearLeft && point.y <= f.minY + corner)
        let topRight = (nearTop && point.x >= f.maxX - corner) || (nearRight && point.y <= f.minY + corner)
        let bottomLeft = (nearBottom && point.x <= f.minX + corner) || (nearLeft && point.y >= f.maxY - corner)
        let bottomRight = (nearBottom && point.x >= f.maxX - corner) || (nearRight && point.y >= f.maxY - corner)

        if topLeft { return .topLeftQuarter }
        if topRight { return .topRightQuarter }
        if bottomLeft { return .bottomLeftQuarter }
        if bottomRight { return .bottomRightQuarter }
        if nearTop { return .maximize }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        return nil
    }

    /// macOS 15.1+ native "drag to menu bar fills screen" fires in exactly
    /// our trigger region. We detect and log the conflict — changing another
    /// domain's preferences belongs behind explicit user consent in
    /// onboarding UI.
    private func warnIfNativeTilingConflicts() {
        guard let windowManager = UserDefaults(suiteName: "com.apple.WindowManager") else { return }
        let key = "EnableTopTilingByEdgeDrag"
        let enabled = windowManager.object(forKey: key) == nil || windowManager.bool(forKey: key)
        if enabled {
            log.notice("""
            native top-edge tiling is on and overlaps the snap trigger band; \
            suggest disabling "Drag windows to top of screen to fill" in \
            System Settings > Desktop & Dock
            """)
        }
    }

    /// Snap a window, then (for a half) offer Snap Assist for the other half.
    /// Shared by palette drops and edge snaps.
    private func snap(_ window: AXWindow, toFrame target: NSRect) {
        place(window, toFrame: target)
        maybeSnapAssist(after: window, snappedTo: target)
    }

    /// Move a window to an AppKit-space frame and remember its pre-snap size so
    /// a later drag restores it. No Snap Assist (used for the assist's own
    /// placement, so it doesn't recurse).
    private func place(_ window: AXWindow, toFrame target: NSRect) {
        log.debug("snapping pid \(window.pid) to \(String(describing: target))")
        let preSnap = window.frame
        WindowMover.move(window, toAppKitRect: target)
        guard let preSnap else { return }
        // Record the size the window ACTUALLY became (some apps clamp), not the
        // requested size, so the later un-snap drag matches reliably. This is
        // what makes a maximized window revert when you drag it again.
        let snappedSize = window.frame?.size ?? target.size
        snapRecords.removeAll { $0.pid == window.pid && Self.sizesMatch($0.snappedSize, snappedSize) }
        snapRecords.append(SnapRecord(pid: window.pid, snappedSize: snappedSize, preSnap: preSnap))
        if snapRecords.count > 40 { snapRecords.removeFirst(snapRecords.count - 40) }
    }

    // MARK: Snap Assist

    private func snapAssistEnabled() -> Bool {
        preferences?.bool(forKey: Self.snapAssistKey, default: true) ?? true
    }

    /// If the window was snapped to a half, show the other windows for the
    /// empty half. Enumeration needs Screen Recording; without it the list is
    /// empty and nothing shows (so snapping itself never depends on it).
    private func maybeSnapAssist(after window: AXWindow, snappedTo target: NSRect) {
        guard snapAssistEnabled() else { return }
        let center = CGPoint(x: target.midX, y: target.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(target) }),
            let complement = Self.complementHalf(of: target, on: screen) else { return }

        let excludePID = window.pid
        let excludeTitle = window.title ?? ""
        pendingAssistRect = complement
        Task { [weak self] in
            guard let self else { return }
            // The window list can come back empty on a cold ScreenCaptureKit
            // call right after launch; retry once before giving up so the
            // picker reliably appears on the first snap.
            for attempt in 0..<2 {
                let items = await self.enumerator.enumerate()
                let others = items.filter { !($0.pid == excludePID && $0.title == excludeTitle) }
                guard self.pendingAssistRect == complement else { return } // superseded
                if !others.isEmpty {
                    self.assistPanel?.show(items: others, in: complement)
                    return
                }
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
    }

    private func fillAssist(with item: WindowEnumerator.Item) {
        guard let rect = pendingAssistRect, let window = enumerator.axWindow(for: item) else { return }
        pendingAssistRect = nil
        if window.isMinimized { window.setMinimized(false) }
        place(window, toFrame: rect)
        // Bring the chosen window forward into its new half.
        window.raise()
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }

    /// The opposite half if `target` is (within tolerance) the left or right
    /// half of `screen`; nil for maximize / quarters / thirds / custom zones.
    private static func complementHalf(of target: NSRect, on screen: NSScreen) -> NSRect? {
        let area = screen.visibleFrame
        let left = NSRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height)
        let right = NSRect(x: area.midX, y: area.minY, width: area.width / 2, height: area.height)
        func matches(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 6 && abs(a.minY - b.minY) < 6
                && abs(a.width - b.width) < 6 && abs(a.height - b.height) < 6
        }
        if matches(target, left) { return right }
        if matches(target, right) { return left }
        return nil
    }

    /// If this window's size still matches what we snapped it to, restore it
    /// to its pre-snap size and place it under the cursor so the in-progress
    /// drag continues naturally (the Windows un-snap gesture).
    private func unsnapIfNeeded(_ window: AXWindow, cursorCG: CGPoint) {
        guard let current = window.frame else { return }
        guard let idx = snapRecords.firstIndex(where: {
            $0.pid == window.pid && Self.sizesMatch(current.size, $0.snappedSize)
        }) else { return }
        let record = snapRecords.remove(at: idx)

        let pre = record.preSnap
        // Keep the cursor at the same horizontal spot on the (now narrower)
        // title bar as the window shrinks back.
        let fraction = current.width > 1 ? (cursorCG.x - current.minX) / current.width : 0.5
        let clamped = min(max(fraction, 0), 1)
        let origin = CGPoint(x: cursorCG.x - clamped * pre.width, y: cursorCG.y - 16)
        window.setFrame(CGRect(origin: origin, size: pre.size))
    }

    private static func sizesMatch(_ a: CGSize, _ b: CGSize, tolerance: CGFloat = 14) -> Bool {
        abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}

/// Weak holder so the hover-delay Timer closure can reach the module without
/// capturing non-Sendable state.
@MainActor
private enum SnapModuleHolder {
    static weak var current: WindowSnappingModule?
}

/// Aero-snap edge and corner targets, resolved against a screen's usable area
/// (which already excludes the menu bar and Dock).
private enum EdgeZone {
    case maximize, leftHalf, rightHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter

    @MainActor
    func frame(in screen: NSScreen) -> NSRect {
        let a = screen.visibleFrame
        switch self {
        case .maximize:           return a
        case .leftHalf:           return NSRect(x: a.minX, y: a.minY, width: a.width / 2, height: a.height)
        case .rightHalf:          return NSRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height)
        case .topLeftQuarter:     return NSRect(x: a.minX, y: a.midY, width: a.width / 2, height: a.height / 2)
        case .topRightQuarter:    return NSRect(x: a.midX, y: a.midY, width: a.width / 2, height: a.height / 2)
        case .bottomLeftQuarter:  return NSRect(x: a.minX, y: a.minY, width: a.width / 2, height: a.height / 2)
        case .bottomRightQuarter: return NSRect(x: a.midX, y: a.minY, width: a.width / 2, height: a.height / 2)
        }
    }
}
