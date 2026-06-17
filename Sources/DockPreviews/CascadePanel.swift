import AppKit
import PanesCore

/// Stacked / cascade layout for a Dock icon's windows.
///
/// There is no backing panel: the preview cards and the little chevron button
/// float in open space, each with its own surface and shadow. Collapsed shows
/// the front window with the rest peeking behind it as a deck. Opening it fans
/// the windows into a column that grows away from the Dock — separated boxes
/// when there's room, tightening into an overlap only when there are many — and
/// moving the cursor through an overlap spreads the windows after the one you
/// point at to reveal it. The button trails the growth direction; tapping it
/// collapses the cascade.
@MainActor
final class CascadePanel {
    enum OpenTrigger { case hoverButton, clickButton, hoverStack }

    private let panel: OverlayPanel
    private let host = NSView()
    private let button = OblongButton()
    private let backing = FrostedBackingView()

    /// When true, a light frosted backdrop sits behind the cards (blurring the
    /// Dock label and anything else behind the previews). When false the cards
    /// float in open space.
    var frostedBacking = false {
        didSet { backing.isHidden = !frostedBacking }
    }

    var onSelect: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onClose: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onMinimize: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onFullScreen: ((WindowThumbnailService.Thumbnail) -> Void)?

    var monochromeLights = false
    var previewScale: CGFloat = 1
    var openTrigger: OpenTrigger = .hoverButton

    // MARK: Layout constants
    // Generous margin so the frosted backing stays solid under the cards and
    // its feathered halo fades out beyond them, like a soft drop shadow.
    private let inset: CGFloat = 20
    private let buttonH: CGFloat = 18
    private let buttonW: CGFloat = 46
    private let buttonGap: CGFloat = 8
    private let deckStep: CGFloat = 7       // collapsed: how far each back peeks
    private let maxDeckBacks = 3
    private let separationGap: CGFloat = 14  // gap between fully-separated boxes (≤4 windows)
    private let firstOverlap: CGFloat = 22   // overlap at 5 windows — a gentle slide
    private let overlapRampStart = 5         // window count where overlap begins
    private let overlapRampEnd = 12          // window count where overlap reaches its cap
    private let minVisibleStrip: CGFloat = 56 // tightest: how much of an overlapped card still shows
    private let gap: CGFloat = 2   // sit close to the icon so the backing covers its label
    private let expandDelay: TimeInterval = 0.18

    // MARK: State
    private var thumbnails: [WindowThumbnailService.Thumbnail] = []
    private var cards: [ThumbnailCardView] = []
    private var expanded = false
    private var axisUp = true
    private var focusIndex: Int?
    private var anchor: NSRect = .zero
    private var edge: DockModel.Edge = .bottom
    private var screenFrame: NSRect = .zero
    private var stableFrame: NSRect = .zero
    private var expandTimer: Timer?
    private var waterfallTask: Task<Void, Never>?
    private var isWaterfalling = false

    private var cardW: CGFloat { (180 * previewScale).rounded() }
    private var cardH: CGFloat { (144 * previewScale).rounded() }

    // Small margin on the side facing the Dock (so the cards sit close to the
    // icon), the big halo margin on the outer sides.
    private let nearMargin: CGFloat = 8
    private var leftMargin: CGFloat { edge == .left ? nearMargin : inset }
    private var rightMargin: CGFloat { edge == .right ? nearMargin : inset }
    private var panelW: CGFloat { cardW + leftMargin + rightMargin }

    init() {
        panel = OverlayPanel(level: .statusBar)
        // No backing surface and no window shadow — the cards and button float
        // and carry their own shadows.
        panel.hasShadow = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        backing.isHidden = true
        host.addSubview(backing)            // stays at the back, behind the cards
        button.onHover = { [weak self] inside in self?.buttonHover(inside) }
        button.onClick = { [weak self] in self?.buttonClicked() }
        host.addSubview(button)
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }

    func frameCG() -> CGRect? {
        guard panel.isVisible else { return nil }
        // The settled target frame, not panel.frame — which is mid-animation
        // during an expand and would make the dismissal poll think the cursor
        // briefly left the panel.
        return ScreenGeometry.cgRect(fromAppKit: stableFrame)
    }

    func hide() {
        cancelExpand()
        waterfallTask?.cancel()
        panel.orderOut(nil)
        expanded = false
        focusIndex = nil
    }

    /// Scroll-to-pick selection: fan the stack open (scrolling is itself an
    /// open trigger) and raise/lift the chosen card. nil clears the highlight.
    func highlight(index: Int?) {
        guard let index else {
            setFocusHighlight(nil)
            return
        }
        if !expanded { expand() }
        focusIndex = index
        setFocusHighlight(index)
    }

    // MARK: Show

    func show(
        thumbnails: [WindowThumbnailService.Thumbnail],
        anchor anchorCG: CGRect,
        edge: DockModel.Edge,
        dockFrameCG: CGRect?
    ) {
        self.thumbnails = thumbnails
        self.edge = edge
        anchor = ScreenGeometry.appKitRect(fromCG: anchorCG)
        screenFrame = ScreenGeometry.screen(containingCGPoint: CGPoint(x: anchorCG.midX, y: anchorCG.midY))?.frame
            ?? NSScreen.main?.frame ?? .zero
        expanded = false
        focusIndex = nil

        // Cascade direction: a bottom Dock always grows up; a side Dock grows
        // whichever way has more room.
        switch edge {
        case .bottom:
            axisUp = true
        case .left, .right:
            axisUp = (screenFrame.maxY - anchor.midY) >= (anchor.midY - screenFrame.minY)
        }

        buildCards()
        orderZ()
        button.setChevron(up: axisUp)
        applyLayout(animated: false)
        panel.orderFrontRegardless()
    }

    private func buildCards() {
        cards.forEach { $0.removeFromSuperview() }
        cards = thumbnails.enumerated().map { index, thumbnail in
            let card = ThumbnailCardView(monochrome: monochromeLights)
            card.configure(with: thumbnail)
            card.applyFloatingShadow()
            card.onHover = { [weak self] inside in self?.cardHover(index, inside: inside) }
            card.onClick = { [weak self] in self?.fire(\.onSelect, index) }
            card.onClose = { [weak self] in self?.fire(\.onClose, index) }
            card.onMinimize = { [weak self] in self?.fire(\.onMinimize, index) }
            card.onFullScreen = { [weak self] in self?.fire(\.onFullScreen, index) }
            host.addSubview(card)
            return card
        }
    }

    /// Consistent stack order in EVERY state: the newest window (index 0) is on
    /// top, the oldest at the back, z increasing with recency. Keeping it the
    /// same collapsed and expanded means nothing reshuffles when the cascade
    /// opens — the cards just fall into place behind the front one.
    private func orderZ() {
        for index in cards.indices.reversed() {
            host.addSubview(cards[index], positioned: .below, relativeTo: button)
        }
    }

    private func fire(_ key: KeyPath<CascadePanel, ((WindowThumbnailService.Thumbnail) -> Void)?>, _ index: Int) {
        guard index < thumbnails.count else { return }
        self[keyPath: key]?(thumbnails[index])
    }

    // MARK: Geometry

    private func availableLength() -> CGFloat {
        max(160, screenFrame.height - 120)
    }

    /// Distance between successive cards (which equals each card's visible
    /// strip when they overlap). Driven by the window count: up to 4 windows
    /// each show in full with a gap; from 5 they overlap, and the more there
    /// are the more they overlap, down to a floor. Clamped so a tall column
    /// still fits on screen.
    private func cascadeStep() -> CGFloat {
        let n = cards.count
        guard n > 1 else { return 0 }
        let target: CGFloat
        if n <= 4 {
            target = cardH + separationGap
        } else {
            let t = min(CGFloat(n - overlapRampStart) / CGFloat(overlapRampEnd - overlapRampStart), 1)
            let slightStrip = cardH - firstOverlap
            target = slightStrip + (minVisibleStrip - slightStrip) * t
        }
        // Floor the step so a tall stack at a large preview size on a short
        // display can never produce a zero/negative step (which would overlap
        // the cards backwards); the panel just overflows and gets clamped.
        let floor = minVisibleStrip * 0.5
        let fitStep = (availableLength() - cardH) / CGFloat(n - 1)
        return max(floor, min(target, fitStep))
    }

    private func cardFrameAt(distance d: CGFloat, height: CGFloat) -> NSRect {
        let y = axisUp ? inset + d : height - inset - d - cardH
        return NSRect(x: leftMargin, y: y, width: cardW, height: cardH)
    }

    /// Even spacing — the layout never shifts on scrub. Pointing at a card
    /// raises it to the front instead of pushing its neighbours around, so
    /// scrubbing stays calm.
    private func cascadeDistances(step: CGFloat) -> [CGFloat] {
        cards.indices.map { CGFloat($0) * step }
    }

    private func cardsContentH(step: CGFloat) -> CGFloat {
        if expanded {
            guard cards.count > 1 else { return cardH }
            return CGFloat(cards.count - 1) * step + cardH
        }
        return cardH + CGFloat(min(cards.count - 1, maxDeckBacks)) * deckStep
    }

    private func panelHeight(step: CGFloat) -> CGFloat {
        inset + cardsContentH(step: step) + buttonGap + buttonH + inset
    }

    private func panelOrigin(height: CGFloat) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        switch edge {
        case .bottom:
            x = anchor.midX - panelW / 2
            y = anchor.maxY + gap
        case .left:
            x = anchor.maxX + gap
            y = sideDockOriginY(height: height)
        case .right:
            x = anchor.minX - gap - panelW
            y = sideDockOriginY(height: height)
        }
        if screenFrame.width > 0 {
            x = max(screenFrame.minX + 6, min(x, screenFrame.maxX - panelW - 6))
            y = max(screenFrame.minY + 6, min(y, screenFrame.maxY - height - 6))
        }
        return NSPoint(x: x, y: y)
    }

    /// For a side Dock, place the panel so the FRONT card sits straight out from
    /// the icon — centered on it, like the single-window preview — with the rest
    /// of the stack fanning away from there.
    private func sideDockOriginY(height: CGFloat) -> CGFloat {
        let frontCardCenter = axisUp ? (inset + cardH / 2) : (height - inset - cardH / 2)
        return anchor.midY - frontCardCenter
    }

    private func applyLayout(animated: Bool) {
        let step = cascadeStep()
        let height = panelHeight(step: step)
        let frame = NSRect(origin: panelOrigin(height: height), size: NSSize(width: panelW, height: height))
        stableFrame = frame
        let distances = cascadeDistances(step: step)
        // The button trails the cascade: at the growth end (the far side from
        // the Dock), so it sits below a downward cascade and above an upward one.
        let buttonRect = NSRect(
            x: (panelW - buttonW) / 2,
            y: axisUp ? height - inset - buttonH : inset,
            width: buttonW, height: buttonH
        )

        func cardFrame(_ index: Int) -> NSRect {
            let d = expanded ? distances[index] : CGFloat(min(index, maxDeckBacks)) * deckStep
            return cardFrameAt(distance: d, height: height)
        }
        func cardAlpha(_ index: Int) -> CGFloat { expanded || index <= maxDeckBacks ? 1 : 0 }
        let backingRect = NSRect(x: 0, y: 0, width: panelW, height: height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                backing.animator().frame = backingRect
                for (index, card) in cards.enumerated() {
                    card.animator().frame = cardFrame(index)
                    card.animator().alphaValue = cardAlpha(index)
                }
                button.animator().frame = buttonRect
            }
        } else {
            panel.setFrame(frame, display: true)
            backing.frame = backingRect
            for (index, card) in cards.enumerated() {
                card.frame = cardFrame(index)
                card.alphaValue = cardAlpha(index)
            }
            button.frame = buttonRect
        }
    }

    // MARK: Expand / collapse

    private func expand() {
        guard !expanded, cards.count > 1 else { return }
        cancelExpand()
        waterfallTask?.cancel()
        expanded = true
        focusIndex = 0
        button.setChevron(up: !axisUp) // now points back toward the Dock (collapse)
        setFocusHighlight(0)

        let step = cascadeStep()
        let height = panelHeight(step: step)
        let frame = NSRect(origin: panelOrigin(height: height), size: NSSize(width: panelW, height: height))
        stableFrame = frame
        let distances = cascadeDistances(step: step)

        // Snap the (transparent) window to the expanded size — invisible — and
        // place the button. The front card's screen spot is preserved by
        // sideDockOriginY, so nothing visible jumps.
        panel.setFrame(frame, display: true)
        button.frame = NSRect(
            x: (panelW - buttonW) / 2,
            y: axisUp ? height - inset - buttonH : inset,
            width: buttonW, height: buttonH
        )

        // The backing starts hugging the collapsed deck and grows to fill as the
        // cascade extends, so there's no instant frosted pop.
        let collapsedContent = cardH + CGFloat(min(cards.count - 1, maxDeckBacks)) * deckStep
        let collapsedH = inset + collapsedContent + buttonGap + buttonH + inset
        backing.frame = axisUp
            ? NSRect(x: 0, y: 0, width: panelW, height: collapsedH)
            : NSRect(x: 0, y: height - collapsedH, width: panelW, height: collapsedH)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backing.animator().frame = NSRect(x: 0, y: 0, width: panelW, height: height)
        }

        // Every card starts stacked behind the front one (the collapsed deck);
        // the ones that were hidden fade in as they fall.
        for (i, card) in cards.enumerated() {
            card.frame = cardFrameAt(distance: CGFloat(min(i, maxDeckBacks)) * deckStep, height: height)
            card.alphaValue = i <= maxDeckBacks ? 1 : 0
        }

        // Waterfall: the front card is already in place; deal the rest out
        // near-to-far, each falling on a spring so it eases out and settles
        // smoothly rather than starting at full speed.
        isWaterfalling = true
        waterfallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWaterfalling = false }
            for i in 1..<self.cards.count {
                if Task.isCancelled { return }
                let card = self.cards[i]
                let target = self.cardFrameAt(distance: distances[i], height: height)
                self.springCard(card, to: target, fadeIn: card.alphaValue < 1)
                try? await Task.sleep(for: .milliseconds(55))
            }
        }
    }

    /// Move a card to a new frame on a spring (eases out, settles softly),
    /// optionally fading it in.
    private func springCard(_ card: ThumbnailCardView, to target: NSRect, fadeIn: Bool) {
        let oldPos = card.layer?.position ?? .zero
        card.frame = target
        let newPos = card.layer?.position ?? .zero
        let spring = CASpringAnimation(keyPath: "position")
        spring.fromValue = NSValue(point: oldPos)
        spring.toValue = NSValue(point: newPos)
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 28
        spring.duration = spring.settlingDuration
        card.layer?.add(spring, forKey: "fall")
        if fadeIn {
            card.alphaValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.22
            card.layer?.add(fade, forKey: "fade")
        }
    }

    private func collapseToDeck() {
        guard expanded else { return }
        waterfallTask?.cancel()
        expanded = false
        focusIndex = nil
        button.setChevron(up: axisUp)
        setFocusHighlight(nil)
        applyLayout(animated: true)
    }

    private func scheduleExpand() {
        guard !expanded, expandTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: expandDelay, repeats: false) { _ in
            MainActor.assumeIsolated { CascadeHolder.current?.expand() }
        }
        expandTimer = timer
        CascadeHolder.current = self
    }

    private func cancelExpand() {
        expandTimer?.invalidate()
        expandTimer = nil
    }

    // MARK: Interaction

    private func buttonHover(_ inside: Bool) {
        button.setHighlighted(inside)
        guard openTrigger == .hoverButton, !expanded else { return }
        if inside { scheduleExpand() } else { cancelExpand() }
    }

    /// Tapping the button always toggles — so it can collapse the cascade no
    /// matter how it was opened.
    private func buttonClicked() {
        if expanded { collapseToDeck() } else { expand() }
    }

    private func cardHover(_ index: Int, inside: Bool) {
        if !expanded {
            if openTrigger == .hoverStack {
                if inside { scheduleExpand() } else { cancelExpand() }
            }
            return
        }
        guard inside, focusIndex != index else { return }
        // Ignore stray hovers while the cascade is still falling into place, so
        // the button sliding out from under the cursor can't interrupt it.
        if isWaterfalling { return }
        focusIndex = index
        // Layout is static, so a scrub only raises and lifts the focused card —
        // nothing else moves.
        setFocusHighlight(index)
    }

    private func setFocusHighlight(_ index: Int?) {
        for (i, card) in cards.enumerated() {
            card.setFocused(i == index)
            card.setLifted(i == index)
        }
        // Raise the focused card above every other card so nothing covers it,
        // while keeping the rest in their stable newest-on-top order.
        orderZ()
        if let index { host.addSubview(cards[index], positioned: .below, relativeTo: button) }
    }
}

@MainActor
private enum CascadeHolder {
    static weak var current: CascadePanel?
}

/// The little frosted-glass pill that opens the cascade, with a chevron
/// pointing the way it will fan out. The frost is clipped to the pill shape by
/// `frostHost`; the outer view carries the shadow so it floats.
private final class OblongButton: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private let chevron = NSImageView()
    private let frostHost = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        frostHost.wantsLayer = true
        frostHost.layer?.cornerRadius = 9
        frostHost.layer?.masksToBounds = true
        frostHost.layer?.borderWidth = 1
        frostHost.layer?.borderColor = NSColor.separatorColor.cgColor
        frostHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frostHost)

        let frost = NSVisualEffectView()
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.translatesAutoresizingMaskIntoConstraints = false
        frostHost.addSubview(frost)

        chevron.contentTintColor = .secondaryLabelColor
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false
        frostHost.addSubview(chevron)

        NSLayoutConstraint.activate([
            frostHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            frostHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            frostHost.topAnchor.constraint(equalTo: topAnchor),
            frostHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            frost.leadingAnchor.constraint(equalTo: frostHost.leadingAnchor),
            frost.trailingAnchor.constraint(equalTo: frostHost.trailingAnchor),
            frost.topAnchor.constraint(equalTo: frostHost.topAnchor),
            frost.bottomAnchor.constraint(equalTo: frostHost.bottomAnchor),
            chevron.centerXAnchor.constraint(equalTo: frostHost.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: frostHost.centerYAnchor),
        ])
        setChevron(up: true)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
    }

    func setChevron(up: Bool) {
        chevron.image = NSImage(
            systemSymbolName: up ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    func setHighlighted(_ on: Bool) {
        frostHost.layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : NSColor.separatorColor.cgColor
        frostHost.layer?.borderWidth = on ? 2 : 1
        chevron.contentTintColor = on ? .labelColor : .secondaryLabelColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    // Treat the whole pill as one control — the frost and chevron are decoration.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
