import AppKit
import ApplicationServices
import PanesCore

/// Carries a raw AX element across to a background queue for a concurrent
/// minimize. AXUIElement is thread-safe for these writes; the wrapper just
/// satisfies Sendable checking.
private nonisolated struct SendableAXElement: @unchecked Sendable {
    let raw: AXUIElement
}

public final class DockPreviewsModule: FeatureModule {
    public static let hoverDelayKey = "dock-previews.hoverDelay"
    public static let monochromeKey = "dock-previews.monochromeLights"
    public static let previewSizeKey = "dock-previews.previewSize"
    public static let layoutModeKey = "dock-previews.layoutMode"
    public static let openTriggerKey = "dock-previews.openTrigger"
    public static let minimizeActionKey = "dock-previews.minimizeAction"
    public static let backingStyleKey = "dock-previews.backingStyle"
    public static let scrollToPickKey = "dock-previews.scrollToPick"

    /// In "Automatic" layout, the window count at which previews switch from a
    /// side-by-side row to the stacked cascade.
    private static let autoStackThreshold = 4

    public let metadata = ModuleMetadata(
        id: "dock-previews",
        displayName: "Dock Previews",
        category: "Dock",
        summary: "Hover over a Dock icon to see live previews of that app's open windows. Click one to jump to it, or use the buttons on each preview to close, minimize, or full screen the window.",
        howToUse: "Move your mouse over any open app's Dock icon. After a short delay, previews of its windows appear next to the icon. Click a preview to bring that window to the front, or use the red, yellow, and green buttons above each one to close, minimize, or full screen it. If another app already shows window previews from the Dock, quit it first to avoid conflicts.",
        requiredPermissions: [.accessibility, .screenRecording],
        options: [
            // Visual options first, so they sit next to the live preview in
            // Settings while you adjust them.
            .slider(
                key: previewSizeKey,
                title: "Preview size",
                detail: "How big each preview is.",
                min: 70, max: 160, step: 10, unit: "%", default: 100
            ),
            .choice(
                key: backingStyleKey,
                title: "Background",
                detail: "Frosted puts a soft blur behind the previews. Clear lets them float, but the Dock's app name can show through the gaps.",
                options: ["Frosted", "Clear"],
                defaultIndex: 0
            ),
            .toggle(
                key: monochromeKey,
                title: "Gray window buttons",
                detail: "Show the window buttons in gray instead of red, yellow, and green.",
                defaultOn: false
            ),
            .slider(
                key: hoverDelayKey,
                title: "Preview delay",
                detail: "How long to hover a Dock icon before previews appear. Lower feels snappier.",
                min: 0.0, max: 1.0, step: 0.05, unit: "s", default: 0.35
            ),
            .choice(
                key: layoutModeKey,
                title: "Multiple windows",
                detail: "How several open windows appear. Side by side is a row, stacked fans them out from a button, automatic picks based on how many.",
                options: ["Side by side", "Stacked", "Automatic"],
                defaultIndex: 2
            ),
            .choice(
                key: openTriggerKey,
                title: "Open the stack by",
                detail: "How the stack fans out: hover the button, click it, or hover anywhere on the stack.",
                options: ["Hovering the button", "Clicking the button", "Hovering the stack"],
                defaultIndex: 0
            ),
            .toggle(
                key: scrollToPickKey,
                title: "Scroll to pick a window",
                detail: "Scroll over a Dock icon to step through its windows, then click the icon to open the highlighted one.",
                defaultOn: true
            ),
            .choice(
                key: minimizeActionKey,
                title: "Minimize button",
                detail: "What the minimize button does: just this window, all windows, only the front one, or hide them all at once with no animation.",
                options: ["This window", "All windows", "Most recent", "Hide all"],
                defaultIndex: 0
            ),
        ]
    )

    private var monitor: DockHoverMonitor?
    private var rowPanel: PreviewPanel?
    private var cascadePanel: CascadePanel?
    private weak var activeSurface: (any PreviewSurface)?
    private var thumbnailService: WindowThumbnailService?
    private weak var dock: DockModel?
    private weak var preferences: PreferencesStore?
    private weak var eventTaps: EventTapHub?
    private var scrollToken: EventTapHub.Token?
    private var clickToken: EventTapHub.Token?

    /// The window currently highlighted by scrolling over the Dock icon (nil
    /// when the user hasn't scrolled). A click on the icon commits it.
    private var scrollHighlightIndex: Int?
    /// Accumulates high-resolution (trackpad / Magic Mouse) scroll deltas so a
    /// continuous swipe advances one window at a time, not all at once.
    private var scrollAccumulator: CGFloat = 0
    private static let preciseScrollStep: CGFloat = 22

    private var hoverGeneration = 0
    private var showTimer: Timer?
    /// True while we've forced an auto-hide Dock to stay revealed for a preview.
    private var dockHeld = false
    private var current: (app: NSRunningApplication, item: DockModel.Item)?
    /// The windows currently on screen, in front-to-back order (index 0 is the
    /// frontmost / most recent), so a bulk minimize acts on exactly what's shown.
    private var shownThumbnails: [WindowThumbnailService.Thumbnail] = []

    /// While a preview is visible, this timer polls the cursor location and
    /// dismisses once the cursor has been off BOTH the hovered icon and the
    /// panel for a short grace period. Polling (instead of reacting to each
    /// mouse-move) is what makes dismissal reliable: a move-driven timer that
    /// re-arms on every event never elapses while the cursor keeps moving —
    /// which is exactly why the previews were sticking.
    private var pollTimer: Timer?
    private var offTargetSince: ContinuousClock.Instant?

    public init() {}

    public func start(context: ModuleContext) {
        dock = context.dock
        preferences = context.preferences
        eventTaps = context.eventTaps
        recoverDockHold()

        let service = WindowThumbnailService()
        service.prewarm()
        thumbnailService = service

        let rowPanel = PreviewPanel()
        wire(rowPanel)
        self.rowPanel = rowPanel

        let cascadePanel = CascadePanel()
        wire(cascadePanel)
        self.cascadePanel = cascadePanel

        let monitor = DockHoverMonitor(
            dock: context.dock,
            onHover: { [weak self] item, app in self?.hoverChanged(item: item, app: app) },
            onLeave: { [weak self] in self?.dockLeft() } // evaluate immediately on dock-leave
        )
        monitor.start()
        self.monitor = monitor

        // Scroll over a Dock icon (while its preview is up) to step a highlight
        // through the windows; a click on the icon then opens the highlighted
        // one. Both consume only when actually steering a selection, so the
        // system-wide miss path is a couple of cheap checks.
        scrollToken = context.eventTaps.subscribe(to: [.scrollWheel], wantsConsume: true) { [weak self] _, event in
            self?.handleScroll(event) ?? .pass
        }
        clickToken = context.eventTaps.subscribe(to: [.leftMouseDown], wantsConsume: true) { [weak self] _, event in
            self?.handleCommitClick(event) ?? .pass
        }
    }

    /// Route a surface's per-window actions back through the module's handlers.
    private func wire(_ surface: any PreviewSurface) {
        surface.onSelect = { [weak self] thumbnail in self?.raise(thumbnail) }
        surface.onClose = { [weak self] thumbnail in self?.closeWindow(thumbnail) }
        surface.onMinimize = { [weak self] thumbnail in self?.minimize(thumbnail) }
        surface.onFullScreen = { [weak self] thumbnail in self?.fullScreen(thumbnail) }
    }

    public func stop() {
        releaseDock()  // never leave the Dock's auto-hide disabled behind us
        if let token = scrollToken { eventTaps?.unsubscribe(token) }
        if let token = clickToken { eventTaps?.unsubscribe(token) }
        scrollToken = nil
        clickToken = nil
        clearScrollHighlight()
        monitor?.stop()
        monitor = nil
        stopPolling()
        rowPanel?.hide()
        cascadePanel?.hide()
        rowPanel = nil
        cascadePanel = nil
        activeSurface = nil
        thumbnailService = nil
        showTimer?.invalidate(); showTimer = nil
        current = nil
        hoverGeneration += 1
    }

    // MARK: Hover → debounce → show

    private func hoverChanged(item: DockModel.Item, app: NSRunningApplication) {
        offTargetSince = nil
        if app.processIdentifier == current?.app.processIdentifier, activeSurface?.isVisible == true { return }

        current = (app, item)
        clearScrollHighlight() // moving to a different icon drops any prior selection
        showTimer?.invalidate()
        let delay = preferences?.double(forKey: Self.hoverDelayKey, default: 0.35) ?? 0.35
        if delay <= 0.01 {
            loadAndShow()
        } else {
            showTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { DockPreviewsHolder.current?.loadAndShow() }
            }
            DockPreviewsHolder.current = self
        }
    }

    private func loadAndShow() {
        showTimer?.invalidate(); showTimer = nil
        guard let current, let service = thumbnailService else { return }
        hoverGeneration += 1
        let generation = hoverGeneration
        let app = current.app
        // Re-read the hovered icon's frame fresh (it may have moved since the
        // hover fired, e.g. an auto-hide Dock finished sliding in).
        let anchorCG = dock?.selectedItem()?.frame ?? current.item.frame
        let edge = dock?.edge() ?? .bottom
        let dockFrameCG = dock?.dockFrame()

        // User-chosen preview size (70–160%), as a 0.7–1.6 multiplier. Scale
        // the capture resolution to match so bigger previews stay crisp.
        let scale = (preferences?.double(forKey: Self.previewSizeKey, default: 100) ?? 100) / 100
        let maxPixelWidth = Int(520 * max(scale, 1))

        Task { [weak self] in
            guard let self else { return }
            let thumbnails = await service.thumbnails(for: app, maxPixelWidth: maxPixelWidth)
            guard generation == self.hoverGeneration else { return }
            guard !thumbnails.isEmpty else {
                // A transient empty read (an AX hiccup mid-interaction) must not
                // blank a preview that's already up — only hide if nothing is
                // showing yet. A real close is handled when the cursor leaves.
                if self.activeSurface?.isVisible != true {
                    self.hideSurfaces()
                    self.stopPolling()
                }
                return
            }

            self.shownThumbnails = thumbnails
            let useStack = self.useStackLayout(windowCount: thumbnails.count)
            let surface: (any PreviewSurface)? = useStack ? self.cascadePanel : self.rowPanel
            guard let surface else { return }
            // Hide the other surface so only one is ever on screen.
            (useStack ? self.rowPanel : self.cascadePanel as (any PreviewSurface)?)?.hide()

            surface.monochromeLights = self.preferences?.bool(forKey: Self.monochromeKey, default: false) ?? false
            surface.previewScale = scale
            surface.frostedBacking = self.useFrostedBacking()
            if let cascade = surface as? CascadePanel {
                cascade.openTrigger = self.openTrigger()
            }
            surface.show(thumbnails: thumbnails, anchor: anchorCG, edge: edge, dockFrameCG: dockFrameCG)
            self.activeSurface = surface
            self.startPolling()
            self.holdDock()
        }
    }

    /// Resolve the "Multiple windows" setting (and window count) to a layout.
    /// A single window is always a lone card — never a stack.
    private func useStackLayout(windowCount: Int) -> Bool {
        guard windowCount > 1 else { return false }
        switch Int((preferences?.double(forKey: Self.layoutModeKey, default: 2) ?? 2).rounded()) {
        case 0: return false                                   // Side by side
        case 1: return true                                    // Stacked
        default: return windowCount >= Self.autoStackThreshold // Automatic
        }
    }

    private func useFrostedBacking() -> Bool {
        // Index 0 = Frosted, 1 = Clear.
        Int((preferences?.double(forKey: Self.backingStyleKey, default: 0) ?? 0).rounded()) == 0
    }

    private func openTrigger() -> CascadePanel.OpenTrigger {
        switch Int((preferences?.double(forKey: Self.openTriggerKey, default: 0) ?? 0).rounded()) {
        case 1: return .clickButton
        case 2: return .hoverStack
        default: return .hoverButton
        }
    }

    private func hideSurfaces() {
        rowPanel?.hide()
        cascadePanel?.hide()
        activeSurface = nil
        releaseDock()
    }

    /// Keep an auto-hide Dock revealed while a preview is up, so moving onto the
    /// preview doesn't slide the Dock away. Only acts when the Dock is actually
    /// set to auto-hide; restored the moment the preview is dismissed.
    private static let dockHeldKey = "dock-previews.dockHeldAutohide"

    private func holdDock() {
        guard !dockHeld, DockAutohide.isEnabled == true else { return }
        // Breadcrumb set BEFORE disabling: if we crash while holding, the next
        // launch restores auto-hide (see recoverDockHold()).
        UserDefaults.standard.set(true, forKey: Self.dockHeldKey)
        DockAutohide.setEnabled(false)
        dockHeld = true
    }

    private func releaseDock() {
        guard dockHeld else { return }
        dockHeld = false
        // Only restore if it's still disabled (i.e. we left it that way). If the
        // user turned auto-hide back on themselves while a preview was up, leave
        // their choice alone.
        if DockAutohide.isEnabled == false {
            DockAutohide.setEnabled(true)
        }
        UserDefaults.standard.removeObject(forKey: Self.dockHeldKey)
    }

    /// If a previous run died while holding the Dock revealed, restore the
    /// user's auto-hide now. Call once at start.
    private func recoverDockHold() {
        guard UserDefaults.standard.bool(forKey: Self.dockHeldKey) else { return }
        DockAutohide.setEnabled(true)
        UserDefaults.standard.removeObject(forKey: Self.dockHeldKey)
    }

    // MARK: Actions from the preview

    private func raise(_ thumbnail: WindowThumbnailService.Thumbnail) {
        if let ax = thumbnail.axWindow {
            if ax.isMinimized { ax.setMinimized(false) }
            ax.raise()
        } else {
            current?.app.activate()
        }
        hideNow()
    }

    /// The time of the last close/minimize/full-screen from a preview button.
    private var lastCardActionAt: ContinuousClock.Instant?

    /// Guard destructive preview-button actions against rapid repeats — mouse
    /// chatter, or a reload sliding another button under the cursor — so one
    /// stray press can't destroy several windows.
    private func allowCardAction() -> Bool {
        let now = ContinuousClock.now
        if let last = lastCardActionAt, now - last < .milliseconds(500) { return false }
        lastCardActionAt = now
        return true
    }

    private func closeWindow(_ thumbnail: WindowThumbnailService.Thumbnail) {
        guard allowCardAction(), let ax = thumbnail.axWindow else { return }
        ax.close()
        thumbnailService?.invalidate()
        // Dismiss the preview after a close rather than reloading in place: a
        // reload slides the next window's close button under the cursor, so a
        // stray or repeated click would walk down the stack closing everything
        // (which loses browser tabs). Re-hover to close another.
        hideNow()
    }

    private enum MinimizeAction { case thisWindow, allWindows, mostRecent, hideApp }

    private func minimizeAction() -> MinimizeAction {
        switch Int((preferences?.double(forKey: Self.minimizeActionKey, default: 0) ?? 0).rounded()) {
        case 1: return .allWindows
        case 2: return .mostRecent
        case 3: return .hideApp
        default: return .thisWindow
        }
    }

    /// Minimize per the chosen setting: just the clicked window, every window
    /// of the app at once, or only the frontmost (most recent) one.
    private func minimize(_ thumbnail: WindowThumbnailService.Thumbnail) {
        guard allowCardAction() else { return }
        switch minimizeAction() {
        case .thisWindow:
            thumbnail.axWindow?.setMinimized(true)
        case .allWindows:
            // Fire every minimize concurrently so a slow-to-respond app (Edge
            // and other Chromium browsers especially) minimizes them all at
            // once, instead of one-after-another as each blocking AX call lands.
            for window in shownThumbnails.compactMap(\.axWindow) where !window.isMinimized {
                let element = SendableAXElement(raw: window.element.raw)
                DispatchQueue.global(qos: .userInitiated).async {
                    AXUIElementSetAttributeValue(element.raw, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                }
            }
        case .mostRecent:
            let front = shownThumbnails.first { !($0.axWindow?.isMinimized ?? true) }?.axWindow
            (front ?? thumbnail.axWindow)?.setMinimized(true)
        case .hideApp:
            // Hiding is the only way to clear every window at once with no
            // per-window genie — they vanish together, instantly.
            current?.app.hide()
        }
        thumbnailService?.invalidate()
        loadAndShow()
    }

    private func fullScreen(_ thumbnail: WindowThumbnailService.Thumbnail) {
        guard allowCardAction() else { return }
        thumbnail.axWindow?.toggleFullScreen()
        hideNow() // full-screen moves the window to its own Space; dismiss.
    }

    // MARK: Hide — cursor polling

    private static let dismissGrace: Duration = .milliseconds(220)

    private func startPolling() {
        offTargetSince = nil
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
            MainActor.assumeIsolated { DockPreviewsHolder.current?.pollTick() }
        }
        timer.tolerance = 0.03
        pollTimer = timer
        DockPreviewsHolder.current = self
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        offTargetSince = nil
    }

    /// Keep the preview while the cursor is over the panel or the hovered
    /// icon (with a small bridge for the gap between them); otherwise start a
    /// grace countdown and dismiss when it elapses. The countdown is anchored
    /// to a timestamp, so it can't be reset away by continued movement.
    /// Cursor left the Dock. If a preview hasn't appeared yet, cancel the
    /// pending show so a brief hover — or an accidental auto-hide reveal while
    /// reaching for a button near the Dock — doesn't pop a preview afterward.
    private func dockLeft() {
        if showTimer != nil {
            showTimer?.invalidate()
            showTimer = nil
            current = nil
        }
        pollTick()
    }

    private func pollTick() {
        guard let surface = activeSurface, surface.isVisible else { stopPolling(); return }
        let point = ScreenGeometry.mouseLocationCG
        let overPanel = surface.frameCG()?.insetBy(dx: -8, dy: -8).contains(point) ?? false
        let overItem = current?.item.frame.insetBy(dx: -16, dy: -16).contains(point) ?? false

        if overPanel || overItem {
            offTargetSince = nil
            return
        }
        let now = ContinuousClock.now
        if let since = offTargetSince {
            if now - since >= Self.dismissGrace { hideNow() }
        } else {
            offTargetSince = now
        }
    }

    private func hideNow() {
        hoverGeneration += 1
        current = nil
        clearScrollHighlight()
        hideSurfaces()
        stopPolling()
    }

    // MARK: Scroll to pick a window

    private func clearScrollHighlight() {
        scrollHighlightIndex = nil
        scrollAccumulator = 0
        dock?.suppressClickMinimize = false
    }

    /// Step the highlight through the hovered app's windows on scroll — only
    /// while a preview is up and the cursor is over the icon or the panel.
    /// Cheapest checks first so the system-wide scroll path stays light.
    private func handleScroll(_ event: CGEvent) -> EventTapHub.Verdict {
        guard let surface = activeSurface, surface.isVisible, shownThumbnails.count > 1,
              preferences?.bool(forKey: Self.scrollToPickKey, default: true) ?? true else { return .pass }

        let point = ScreenGeometry.mouseLocationCG
        let overItem = current?.item.frame.insetBy(dx: -8, dy: -8).contains(point) ?? false
        let overPanel = surface.frameCG()?.insetBy(dx: -8, dy: -8).contains(point) ?? false
        guard overItem || overPanel else { return .pass }

        let step = scrollStep(from: event)
        if step != 0 { advanceHighlight(by: step) }
        return .consume // swallow while engaged so nothing behind the Dock scrolls
    }

    /// Resolve a scroll event to -1 / 0 / +1. A classic wheel steps once per
    /// notch; a continuous device (trackpad, Magic Mouse) accumulates until it
    /// crosses a threshold, so one swipe advances one window.
    private func scrollStep(from event: CGEvent) -> Int {
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
            scrollAccumulator += CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            guard abs(scrollAccumulator) >= Self.preciseScrollStep else { return 0 }
            let step = scrollAccumulator > 0 ? -1 : 1
            scrollAccumulator = 0
            return step
        }
        let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        return delta > 0 ? -1 : (delta < 0 ? 1 : 0)
    }

    private func advanceHighlight(by step: Int) {
        let count = shownThumbnails.count
        guard count > 0 else { return }
        let base = scrollHighlightIndex ?? 0
        let next = ((base + step) % count + count) % count
        scrollHighlightIndex = next
        activeSurface?.highlight(index: next)
        dock?.suppressClickMinimize = true // let the next icon click commit, not minimize
    }

    /// A click on the hovered icon while a scroll selection is active opens that
    /// window. Clicks on the panel are handled by the cards themselves, so this
    /// only fires for the icon.
    private func handleCommitClick(_ event: CGEvent) -> EventTapHub.Verdict {
        guard let index = scrollHighlightIndex,
              let surface = activeSurface, surface.isVisible,
              shownThumbnails.indices.contains(index),
              let item = current?.item else { return .pass }
        guard item.frame.insetBy(dx: -6, dy: -6).contains(event.location) else {
            // Clicked away from the icon — end the scroll session and let the
            // click act normally (so the suppress flag can't linger).
            clearScrollHighlight()
            return .pass
        }
        let thumbnail = shownThumbnails[index]
        // Raise off the tap callback so a slow AX call can't trip the tap timeout.
        DispatchQueue.main.async { [weak self] in self?.raise(thumbnail) }
        return .consume
    }
}

@MainActor
private enum DockPreviewsHolder {
    static weak var current: DockPreviewsModule?
}
