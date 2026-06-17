import AppKit
import PanesCore

/// The drop-down snap layout palette shown at the top-center of a screen
/// while the user drags a window.
///
/// Crucial constraint: during a drag of ANOTHER app's window, this panel
/// never receives real mouse events (the drag session belongs to the other
/// app). All interaction is therefore driven from outside — the drag monitor
/// feeds global cursor positions into `zone(atCGPoint:)` / `highlight(_:)`.
@MainActor
final class SnapOverlayPanel {
    struct ZoneRef: Equatable {
        let option: Int
        let zone: Int
    }

    /// The full palette (shown expanded) and a small tab hint (shown peeking).
    private let palettePanel: OverlayPanel
    private let tabPanel: OverlayPanel
    private let paletteView = PaletteView()
    private let tabView = SnapTabView()

    /// Like Windows 11 snap layouts: dragging near the top shows a small tab
    /// poking out under the menu bar; hovering it slides the full palette down.
    private(set) var isExpanded = false

    private static let topInset: CGFloat = 10

    init() {
        palettePanel = OverlayPanel(level: .statusBar)
        palettePanel.ignoresMouseEvents = true
        palettePanel.contentView = paletteView

        tabPanel = OverlayPanel(level: .statusBar)
        tabPanel.ignoresMouseEvents = true
        tabPanel.contentView = tabView
    }

    var isVisible: Bool { palettePanel.isVisible || tabPanel.isVisible }

    func setTabHovered(_ hovered: Bool) { tabView.hovered = hovered }
    var contentSize: NSSize { paletteView.intrinsicContentSize }

    /// Replace the layouts shown (built-in presets plus any custom layouts).
    /// Set before the palette is measured/shown so its size is correct.
    func setOptions(_ options: [SnapLayoutOption]) {
        paletteView.options = options
    }

    /// Full palette, top pinned just below the menu bar (AppKit coords).
    func expandedFrame(on screen: NSScreen) -> NSRect {
        let size = contentSize
        return NSRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.maxY - Self.topInset - size.height,
            width: size.width, height: size.height
        )
    }

    /// The small peek tab, sitting just under the menu bar (with a small gap
    /// so it doesn't clip the menu bar's bottom edge).
    private func tabFrame(on screen: NSScreen) -> NSRect {
        let width: CGFloat = 150, height: CGFloat = 18
        return NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.maxY - height - 5,
            width: width, height: height
        )
    }

    /// Whether the cursor (CG top-left coords) is over the peek tab, with a
    /// small margin so it's not a pixel-perfect target.
    func tabContains(cgPoint point: CGPoint, on screen: NSScreen) -> Bool {
        ScreenGeometry.cgRect(fromAppKit: tabFrame(on: screen)).insetBy(dx: -10, dy: -10).contains(point)
    }

    /// Show the small peek tab (collapsing the full palette if it was open).
    func peek(on screen: NSScreen) {
        if palettePanel.isVisible {
            palettePanel.orderOut(nil)
            paletteView.highlighted = nil
        }
        isExpanded = false
        if !tabPanel.isVisible {
            tabPanel.setFrame(tabFrame(on: screen), display: true)
            tabPanel.orderFrontRegardless()
        }
    }

    /// Grow the full palette out of the tab into the rectangle.
    func expand(on screen: NSScreen) {
        guard !isExpanded else { return }
        isExpanded = true

        let target = expandedFrame(on: screen)
        // Start at the tab's size/position, then grow out and fade in so it
        // reads as the tab expanding to form the palette rectangle.
        palettePanel.setFrame(tabFrame(on: screen), display: false)
        palettePanel.alphaValue = 0
        palettePanel.orderFrontRegardless()
        tabPanel.orderOut(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            palettePanel.animator().setFrame(target, display: true)
            palettePanel.animator().alphaValue = 1
        }
    }

    func hide() {
        paletteView.highlighted = nil
        isExpanded = false
        palettePanel.orderOut(nil)
        tabPanel.orderOut(nil)
    }

    /// Hit test a global cursor position (CG top-left coords). Returns a zone
    /// only when expanded — you can't pick from the peek tab.
    func zone(atCGPoint point: CGPoint) -> ZoneRef? {
        guard palettePanel.isVisible, isExpanded else { return nil }
        let appKitPoint = ScreenGeometry.appKitPoint(fromCG: point)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) else { return nil }
        let frame = expandedFrame(on: screen)
        guard frame.contains(appKitPoint) else { return nil }
        let local = NSPoint(x: appKitPoint.x - frame.minX, y: appKitPoint.y - frame.minY)
        return paletteView.zone(at: local)
    }

    func highlight(_ ref: ZoneRef?) {
        paletteView.highlighted = ref
    }
}

/// The little "pull down for snap layouts" tab that peeks under the menu bar.
/// Highlights when you hover it, just before the palette opens.
private final class SnapTabView: NSView {
    private let effect = NSVisualEffectView()
    private let chevron = NSImageView()

    var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            chevron.contentTintColor = hovered ? .labelColor : .secondaryLabelColor
            effect.layer?.borderWidth = hovered ? 1.5 : 0
            effect.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        chevron.image = NSImage(systemSymbolName: "chevron.compact.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Positive moves it DOWN here (this view's vertical axis is flipped).
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }
}

/// Draws one cell per layout option, each containing its miniature zones.
private final class PaletteView: NSView {
    private static let cellSize = NSSize(width: 96, height: 64)
    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 12
    private static let zoneInset: CGFloat = 3

    var highlighted: SnapOverlayPanel.ZoneRef? {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }

    /// The layouts to draw — presets plus any custom layouts the module feeds in.
    var options: [SnapLayoutOption] = SnapLayoutOption.palette {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(options.count)
        return NSSize(
            width: count * Self.cellSize.width + (count - 1) * Self.spacing + 2 * Self.padding,
            height: Self.cellSize.height + 2 * Self.padding
        )
    }

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(
            x: Self.padding + CGFloat(index) * (Self.cellSize.width + Self.spacing),
            y: Self.padding,
            width: Self.cellSize.width,
            height: Self.cellSize.height
        )
    }

    /// Zone rect in view coordinates (AppKit, bottom-up) for a top-down
    /// normalized layout zone.
    private func zoneRect(_ zone: CGRect, in cell: NSRect) -> NSRect {
        let inner = cell.insetBy(dx: Self.zoneInset, dy: Self.zoneInset)
        return NSRect(
            x: inner.minX + zone.minX * inner.width,
            y: inner.maxY - (zone.minY + zone.height) * inner.height,
            width: zone.width * inner.width,
            height: zone.height * inner.height
        ).insetBy(dx: 1.5, dy: 1.5)
    }

    func zone(at point: NSPoint) -> SnapOverlayPanel.ZoneRef? {
        for (optionIndex, option) in options.enumerated() {
            let cell = cellRect(optionIndex)
            guard cell.insetBy(dx: -Self.spacing / 2, dy: -Self.padding).contains(point) else {
                continue
            }
            for (zoneIndex, zone) in option.zones.enumerated() {
                if zoneRect(zone, in: cell).insetBy(dx: -2, dy: -2).contains(point) {
                    return SnapOverlayPanel.ZoneRef(option: optionIndex, zone: zoneIndex)
                }
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        background.fill()

        for (optionIndex, option) in options.enumerated() {
            let cell = cellRect(optionIndex)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: cell, xRadius: 8, yRadius: 8).fill()

            for (zoneIndex, zone) in option.zones.enumerated() {
                let rect = zoneRect(zone, in: cell)
                let isHighlighted = highlighted == SnapOverlayPanel.ZoneRef(
                    option: optionIndex,
                    zone: zoneIndex
                )
                (isHighlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}
