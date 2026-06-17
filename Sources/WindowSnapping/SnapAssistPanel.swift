import AppKit
import PanesCore

/// After a window is snapped to one half, this fills the empty half: a dimmed
/// surface over that region with a card per other window. Click one and it
/// snaps into the space (the Windows "Snap Assist" flow). Reuses the shared
/// `WindowEnumerator` for the window list and live thumbnails.
@MainActor
final class SnapAssistPanel: NSObject, NSWindowDelegate {
    private let panel: AssistWindow
    private let effect = NSVisualEffectView()
    private let grid = NSStackView()
    private let keyView = AssistKeyView()
    private var cards: [AssistCard] = []
    private var items: [WindowEnumerator.Item] = []
    private var previousApp: NSRunningApplication?
    private var shownAt = ContinuousClock.now
    private var timeoutTimer: Timer?

    var onChoose: ((WindowEnumerator.Item) -> Void)?

    private let cardSize = NSSize(width: 196, height: 126)
    private let cardSpacing: CGFloat = 12
    private let margin: CGFloat = 20

    override init() {
        panel = AssistWindow()
        super.init()
        panel.delegate = self

        // Heavier frosted blur (user preferred the stronger look): fully opaque
        // so the background is well softened.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.translatesAutoresizingMaskIntoConstraints = false

        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = cardSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false

        keyView.onCancel = { [weak self] in self?.cancel() }
        keyView.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(grid)
        effect.addSubview(keyView)
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }

    /// Show the picker filling `region` (AppKit coords) with the given windows.
    func show(items: [WindowEnumerator.Item], in region: NSRect) {
        guard !items.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication

        // Columns/rows that fit the region; cap to what fits so it never
        // overflows the half.
        let usableW = region.width - margin * 2
        let usableH = region.height - margin * 2
        let columns = max(1, Int((usableW + cardSpacing) / (cardSize.width + cardSpacing)))
        let maxRows = max(1, Int((usableH + cardSpacing) / (cardSize.height + cardSpacing)))
        let shown = Array(items.prefix(columns * maxRows))
        self.items = shown

        cards.forEach { $0.removeFromSuperview() }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = shown.enumerated().map { index, item in
            let card = AssistCard(size: cardSize)
            card.configure(with: item)
            card.onClick = { [weak self] in self?.choose(index) }
            return card
        }
        var index = 0
        while index < cards.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = cardSpacing
            for card in cards[index..<min(index + columns, cards.count)] {
                row.addArrangedSubview(card)
            }
            grid.addArrangedSubview(row)
            index += columns
        }

        panel.setFrame(region.insetBy(dx: 10, dy: 10), display: true)
        shownAt = ContinuousClock.now
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(keyView)

        // Don't linger if ignored.
        timeoutTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    func hide() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        panel.orderOut(nil)
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        items.removeAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, ContinuousClock.now - shownAt > .milliseconds(200) else { return }
        hide()
    }

    private func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        hide()
        onChoose?(item)
    }

    private func cancel() {
        let app = previousApp
        hide()
        app?.activate()
    }
}

/// Borderless panel that activates, so a single click chooses and Esc cancels.
private final class AssistWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AssistKeyView: NSView {
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

/// One window choice: thumbnail with the app icon and title beneath.
private final class AssistCard: NSView {
    private let imageView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private var hovered = false { didSet { updateBackground() } }

    init(size: NSSize) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        updateBackground()
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 5
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.heightAnchor.constraint(equalToConstant: size.height - 44),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(with item: WindowEnumerator.Item) {
        if let thumb = item.thumbnail {
            imageView.image = NSImage(cgImage: thumb, size: .zero)
        } else {
            imageView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        }
        iconView.image = item.appIcon
        titleLabel.stringValue = item.title
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    private func updateBackground() {
        layer?.backgroundColor = (hovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.45)
            : NSColor.white.withAlphaComponent(0.06)).cgColor
        layer?.borderColor = (hovered ? NSColor.controlAccentColor : NSColor.clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
