import AppKit
import PanesCore

/// Floating strip of window-thumbnail cards anchored to a Dock icon — the
/// side-by-side layout. Nonactivating: the hovered app keeps focus; clicking a
/// card raises that window without ever activating Panes. Each card carries
/// macOS-style traffic-light buttons to close or minimize the window in place.
@MainActor
final class PreviewPanel {
    private let panel: OverlayPanel
    private let stack = NSStackView()
    private let container = HoverReportingView()
    private let backing = FrostedBackingView()

    /// Frosted backdrop vs. floating (clear). The same feathered halo the
    /// cascade uses, so the look is identical no matter how many windows.
    var frostedBacking = true {
        didSet { backing.isHidden = !frostedBacking }
    }

    var onSelect: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onClose: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onMinimize: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onFullScreen: ((WindowThumbnailService.Thumbnail) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    /// When true, the traffic lights render gray instead of red/yellow/green.
    var monochromeLights = false

    /// Multiplier on the base card size, driven by the "Preview size" setting.
    var previewScale: CGFloat = 1

    private var thumbnails: [WindowThumbnailService.Thumbnail] = []
    private var cards: [ThumbnailCardView] = []

    init() {
        panel = OverlayPanel(level: .statusBar)
        // No window shadow — it would trace the panel rectangle and read as a
        // hard outline around the feathered backing. The cards carry their own.
        panel.hasShadow = false

        container.wantsLayer = true
        container.layer?.masksToBounds = false   // let the feather + card shadows show
        container.onHoverChange = { [weak self] inside in self?.onHoverChange?(inside) }

        // The same feathered frosted halo as the cascade, behind the row.
        backing.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backing)

        stack.orientation = .horizontal
        stack.spacing = 10
        // Generous margin so the backing's feather fades out beyond the cards,
        // matching the cascade.
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backing.topAnchor.constraint(equalTo: container.topAnchor),
            backing.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    /// `anchorCG` is the dock item frame, `dockFrameCG` the whole Dock list,
    /// both in CG top-left coordinates. `edge` decides which side of the Dock
    /// the panel sits on so it never overlaps the icons.
    func show(
        thumbnails: [WindowThumbnailService.Thumbnail],
        anchor anchorCG: CGRect,
        edge: DockModel.Edge,
        dockFrameCG: CGRect?
    ) {
        self.thumbnails = thumbnails
        // Small margin on the side facing the Dock, big halo margin elsewhere —
        // matching the cascade, so the cards sit close to the icon.
        let halo: CGFloat = 20
        let near: CGFloat = 8
        switch edge {
        case .bottom: stack.edgeInsets = NSEdgeInsets(top: halo, left: halo, bottom: near, right: halo)
        case .left: stack.edgeInsets = NSEdgeInsets(top: halo, left: near, bottom: halo, right: halo)
        case .right: stack.edgeInsets = NSEdgeInsets(top: halo, left: halo, bottom: halo, right: near)
        }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = thumbnails.enumerated().map { index, thumbnail in
            let card = makeCard(for: thumbnail, index: index)
            stack.addArrangedSubview(card)
            return card
        }
        panel.layoutIfNeeded()
        let size = stack.fittingSize

        let anchor = ScreenGeometry.appKitRect(fromCG: anchorCG)
        let dock = dockFrameCG.map { ScreenGeometry.appKitRect(fromCG: $0) }
        let screen = ScreenGeometry.screen(containingCGPoint: CGPoint(x: anchorCG.midX, y: anchorCG.midY))
        // Sit close to the icon (matching the cascade) so the backing covers
        // the Dock's app-name label.
        let gap: CGFloat = 2

        // Anchor to the hovered ICON, not the Dock list frame — the icon is
        // reliably placed even while an auto-hide Dock is sliding in, whereas
        // the Dock frame can be stale/animating and put the panel on the Dock.
        var origin: NSPoint
        switch edge {
        case .bottom:
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .left:
            origin = NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }

        // Clamp to the full screen (with auto-hide, visibleFrame spans the
        // Dock area anyway — the guard below is what keeps us off the Dock).
        if let bounds = screen?.frame {
            origin.x = max(bounds.minX + 6, min(origin.x, bounds.maxX - size.width - 6))
            origin.y = max(bounds.minY + 6, min(origin.y, bounds.maxY - size.height - 6))
        }

        // Hard guard: never overlap the Dock strip. Only acts on a real
        // intersection, so a stale/off-screen Dock frame can't mis-shove us.
        if let dock {
            let rect = NSRect(origin: origin, size: size)
            if rect.intersects(dock.insetBy(dx: -gap, dy: -gap)) {
                switch edge {
                case .right: origin.x = dock.minX - gap - size.width
                case .left: origin.x = dock.maxX + gap
                case .bottom: origin.y = dock.maxY + gap
                }
            }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Ring the scroll-selected card (nil clears). The row is always laid out,
    /// so this just moves the focus highlight.
    func highlight(index: Int?) {
        for (i, card) in cards.enumerated() {
            card.setFocused(i == index)
        }
    }

    func contains(cgPoint: CGPoint) -> Bool {
        guard panel.isVisible else { return false }
        return panel.frame.contains(ScreenGeometry.appKitPoint(fromCG: cgPoint))
    }

    private func makeCard(for thumbnail: WindowThumbnailService.Thumbnail, index: Int) -> ThumbnailCardView {
        let card = ThumbnailCardView(monochrome: monochromeLights)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: (180 * previewScale).rounded()).isActive = true
        card.heightAnchor.constraint(equalToConstant: (144 * previewScale).rounded()).isActive = true
        card.configure(with: thumbnail)
        card.applyFloatingShadow()
        card.onHover = { [weak card] inside in card?.setFocused(inside) }
        card.onClick = { [weak self] in self?.fire(\.onSelect, index) }
        card.onClose = { [weak self] in self?.fire(\.onClose, index) }
        card.onMinimize = { [weak self] in self?.fire(\.onMinimize, index) }
        card.onFullScreen = { [weak self] in self?.fire(\.onFullScreen, index) }
        return card
    }

    private func fire(_ key: KeyPath<PreviewPanel, ((WindowThumbnailService.Thumbnail) -> Void)?>, _ index: Int) {
        guard index < thumbnails.count else { return }
        self[keyPath: key]?(thumbnails[index])
    }

    /// True when the given point (CG coordinates) is inside any visible part
    /// of the panel — used by the controller's safety-net mouse monitor.
    func frameCG() -> CGRect? {
        guard panel.isVisible else { return nil }
        return ScreenGeometry.cgRect(fromAppKit: panel.frame)
    }
}

/// Reports cursor enter/exit so the controller keeps the panel open while the
/// cursor travels from the Dock icon onto the previews.
final class HoverReportingView: NSView {
    var onHoverChange: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
