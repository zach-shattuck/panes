import AppKit
import PanesCore

/// One window preview: a header bar with traffic-light buttons over a
/// frosted well that the captured window image fills edge-to-edge. Shared by
/// the side-by-side row (`PreviewPanel`) and the stacked cascade
/// (`CascadePanel`). Lays its internals out with Auto Layout against its own
/// bounds, so it works whether its size comes from a constraint (row) or an
/// explicit frame (cascade).
final class ThumbnailCardView: NSView {
    // The captured window fills this layer-backed well edge-to-edge (aspect
    // fill, cropping any overflow) so the outline hugs the real preview with
    // no dark letterbox gap around it.
    private let imageWell = NSView()
    // Shown only when there's no capture (e.g. a truly minimized window).
    private let placeholderView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let header = NSView()
    private let lights = NSStackView()
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onFullScreen: (() -> Void)?
    /// Optional hover callback so a host (the cascade) can react to which card
    /// the cursor is over.
    var onHover: ((Bool) -> Void)?

    init(monochrome: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = Self.restingBackground
        layer?.borderWidth = 1
        layer?.borderColor = Self.restingBorder

        // Traffic lights live in a header bar ABOVE the thumbnail so they
        // never cover the window content. Real macOS order: close, minimize,
        // full-screen.
        let mono = NSColor.tertiaryLabelColor
        let close = TrafficLight(color: monochrome ? mono : .systemRed, symbol: "xmark") { [weak self] in self?.onClose?() }
        let minimize = TrafficLight(color: monochrome ? mono : .systemYellow, symbol: "minus") { [weak self] in self?.onMinimize?() }
        let fullScreen = TrafficLight(color: monochrome ? mono : .systemGreen, symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.onFullScreen?() }
        lights.orientation = .horizontal
        lights.spacing = 7
        lights.translatesAutoresizingMaskIntoConstraints = false
        [close, minimize, fullScreen].forEach(lights.addArrangedSubview)

        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(lights)

        imageWell.wantsLayer = true
        imageWell.layer?.cornerRadius = 6
        imageWell.layer?.masksToBounds = true
        // Fill the well with the capture, cropping overflow rather than
        // letterboxing — no dark gap between the preview and its outline.
        imageWell.layer?.contentsGravity = .resizeAspectFill
        // Empty well = plain frosted glass (light), not a heavy dark box; a
        // real capture covers it completely. The card's own border separates
        // it from its neighbours, so the well needs no outline of its own.
        imageWell.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        imageWell.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.imageScaling = .scaleProportionallyDown
        placeholderView.contentTintColor = .secondaryLabelColor
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        imageWell.addSubview(placeholderView)

        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(imageWell)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 18),
            lights.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 7),
            lights.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            imageWell.topAnchor.constraint(equalTo: header.bottomAnchor),
            imageWell.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageWell.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            placeholderView.centerXAnchor.constraint(equalTo: imageWell.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: imageWell.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: imageWell.bottomAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // Match the layer's contents scale to the display so the aspect-filled
    // capture renders crisply on Retina screens.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        imageWell.layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    func configure(with thumbnail: WindowThumbnailService.Thumbnail) {
        titleLabel.stringValue = thumbnail.title
        if let cgImage = thumbnail.image {
            imageWell.layer?.contents = cgImage
            placeholderView.isHidden = true
        } else {
            imageWell.layer?.contents = nil
            placeholderView.image = NSImage(
                systemSymbolName: thumbnail.isMinimized ? "rectangle.dashed" : "macwindow",
                accessibilityDescription: nil
            )
            placeholderView.isHidden = false
        }
    }

    private var floating = false

    /// Give the card a drop shadow so it reads as floating in open space (the
    /// cascade has no backing panel behind the cards).
    func applyFloatingShadow() {
        floating = true
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    /// Force the highlight ring on/off regardless of hover — used by the
    /// cascade to mark the card the cursor is scrubbed onto.
    func setFocused(_ focused: Bool) { setHighlighted(focused) }

    private var lifted = false

    /// Scale the card up a touch so the focused one reads as floating above the
    /// rest. Springs for a soft, quick pop.
    func setLifted(_ value: Bool) {
        guard lifted != value, let layer else { return }
        lifted = value
        let to: CGFloat = value ? 1.05 : 1
        let from = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (value ? 1 : 1.05)
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = 340
        spring.damping = 24
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "lift")
        layer.transform = CATransform3DMakeScale(to, to, 1)
    }

    // The panel is nonactivating, so without this the first click would be
    // spent just focusing the panel and you'd have to click twice. Accepting
    // first mouse delivers the click to the card on the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Route clicks anywhere on the card to the card itself (which accepts the
    // first mouse), so a single click raises the window even though most of the
    // card is covered by the image well — a plain subview that would otherwise
    // swallow the first click just to focus the panel. The traffic-light
    // buttons keep their own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        var view = super.hitTest(point)
        while let current = view, current !== self {
            if current is TrafficLight { return current }
            view = current.superview
        }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    // Clicks on the lights are consumed by the light views; clicks anywhere
    // else on the card raise the window.
    override func mouseUp(with event: NSEvent) { onClick?() }

    // Hover highlight so it's obvious which window a click will raise.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Fully opaque so a preview never reads through to whatever is behind it,
    /// and overlapping cards stay distinct.
    static let restingBackground = NSColor.windowBackgroundColor.cgColor
    static let restingBorder = NSColor.separatorColor.cgColor

    private func setHighlighted(_ on: Bool) {
        // Keep the card opaque when focused — a translucent accent fill would
        // let whatever is behind the preview read through. Focus shows as the
        // accent border plus, for floating cards, a lift.
        layer?.backgroundColor = Self.restingBackground
        layer?.borderWidth = on ? 2 : 1
        layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : Self.restingBorder
        if floating {
            layer?.shadowOpacity = on ? 0.5 : 0.25
            layer?.shadowRadius = on ? 15 : 9
        }
    }
}

/// A small circular title-bar-style button that reveals its glyph on hover.
final class TrafficLight: NSView {
    private let onClick: () -> Void
    private let glyph = NSImageView()

    init(color: NSColor, symbol: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = color.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true

        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6.5, weight: .bold))
        glyph.contentTintColor = NSColor.black.withAlphaComponent(0.65)
        glyph.isHidden = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // Register the first click even though the panel is nonactivating.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { glyph.isHidden = false }
    override func mouseExited(with event: NSEvent) { glyph.isHidden = true }
    override func mouseDown(with event: NSEvent) { /* swallow so the card doesn't raise */ }
    override func mouseUp(with event: NSEvent) { onClick() }
}
