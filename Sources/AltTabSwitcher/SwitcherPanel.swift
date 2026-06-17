import AppKit
import PanesCore

/// The centered window-switcher overlay: a row of thumbnail cards with a
/// highlighted selection.
///
/// Like the clipboard history (and unlike the Dock previews), this panel
/// ACTIVATES so a single click registers and so Escape / clicking away can
/// dismiss it. It remembers the app you were in and re-activates it if you
/// cancel, so focus returns where it started.
@MainActor
final class SwitcherPanel: NSObject, NSWindowDelegate {
    private let panel: SwitcherWindow
    private let grid = NSStackView()
    private let keyView = KeyView()
    private var cards: [SwitcherCard] = []
    private var items: [WindowEnumerator.Item] = []
    private(set) var selection = 0
    private var previousApp: NSRunningApplication?
    private var shownAt = ContinuousClock.now
    /// Cards per row before wrapping (also clamped to what fits the screen).
    var maxPerRow = 7
    /// The column count actually used for the current layout — drives up/down
    /// arrow navigation between rows.
    private var columns = 1

    var onChoose: ((WindowEnumerator.Item) -> Void)?
    var onCancel: (() -> Void)?

    override init() {
        panel = SwitcherWindow()
        super.init()
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16

        // Vertical grid of horizontal rows; each row centered so a short final
        // row sits in the middle.
        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 12
        grid.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            grid.topAnchor.constraint(equalTo: effect.topAnchor),
            grid.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        keyView.translatesAutoresizingMaskIntoConstraints = false
        keyView.onKey = { [weak self] key in self?.handle(key) }
        effect.addSubview(keyView)
        panel.contentView = effect
    }

    var isVisible: Bool { panel.isVisible }

    func show(items: [WindowEnumerator.Item], initialSelection: Int) {
        self.items = items
        selection = items.isEmpty ? 0 : min(max(0, initialSelection), items.count - 1)
        previousApp = NSWorkspace.shared.frontmostApplication

        cards.forEach { $0.removeFromSuperview() }
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards = items.enumerated().map { index, item in
            let card = SwitcherCard()
            card.configure(with: item)
            card.onClick = { [weak self] in self?.choose(index: index) }
            return card
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        columns = columnCount(for: cards.count, screen: screen)
        // Lay cards out left-to-right, wrapping into new rows at `columns`.
        var index = 0
        while index < cards.count {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 12
            for card in cards[index..<min(index + columns, cards.count)] {
                rowStack.addArrangedSubview(card)
            }
            grid.addArrangedSubview(rowStack)
            index += columns
        }
        refreshHighlight()

        panel.layoutIfNeeded()
        var size = grid.fittingSize
        if let frame = screen?.visibleFrame {
            size.width = min(size.width, frame.width)
            size.height = min(size.height, frame.height)
            panel.setFrame(
                NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                       width: size.width, height: size.height),
                display: true
            )
        }
        shownAt = ContinuousClock.now
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(keyView)
    }

    /// Cards per row: the configured cap, but never more than fit the screen
    /// width or the number of cards.
    private func columnCount(for count: Int, screen: NSScreen?) -> Int {
        guard count > 0 else { return 1 }
        let cardWidth: CGFloat = 220, spacing: CGFloat = 12, inset: CGFloat = 16
        let available = (screen?.visibleFrame.width ?? 1440) - inset * 2
        let fit = max(1, Int((available + spacing) / (cardWidth + spacing)))
        return max(1, min(maxPerRow, min(fit, count)))
    }

    func hide() {
        panel.orderOut(nil)
        cards.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        items.removeAll()
    }

    func advance(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = ((selection + delta) % items.count + items.count) % items.count
        refreshHighlight()
    }

    /// Choose the current selection (Option released / Return).
    func commitSelection() {
        guard items.indices.contains(selection) else { cancel(restoreFocus: true); return }
        choose(index: selection)
    }

    // MARK: NSWindowDelegate — clicking another app dismisses.

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible, ContinuousClock.now - shownAt > .milliseconds(200) else { return }
        // The user clicked elsewhere, which is already taking focus, so don't
        // re-activate the previous app.
        cancel(restoreFocus: false)
    }

    // MARK: Internals

    private func choose(index: Int) {
        guard items.indices.contains(index) else { return }
        onChoose?(items[index])
    }

    private func cancel(restoreFocus: Bool) {
        if restoreFocus { previousApp?.activate() }
        onCancel?()
    }

    private func refreshHighlight() {
        for (index, card) in cards.enumerated() {
            card.setSelected(index == selection)
        }
    }

    private func handle(_ key: KeyView.Key) {
        switch key {
        case .left: advance(by: -1)
        case .right: advance(by: 1)
        case .up: moveRow(-1)
        case .down: moveRow(1)
        case .confirm: commitSelection()
        case .cancel: cancel(restoreFocus: true) // Esc returns focus where it was
        }
    }

    /// Move the selection up/down a row (by the current column count), clamped
    /// so it doesn't wrap off the grid.
    private func moveRow(_ delta: Int) {
        guard !items.isEmpty else { return }
        let target = selection + delta * columns
        guard target >= 0, target < items.count else { return }
        selection = target
        refreshHighlight()
    }
}

/// Borderless panel that activates, so clicks and keys work on the first try.
private final class SwitcherWindow: NSPanel {
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

/// Borderless panels don't get keyDown unless a first responder accepts it.
private final class KeyView: NSView {
    enum Key { case left, right, up, down, confirm, cancel }
    var onKey: ((Key) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onKey?(.left)
        case 124: onKey?(.right)
        case 126: onKey?(.up)
        case 125: onKey?(.down)
        case 48:  onKey?(event.modifierFlags.contains(.shift) ? .left : .right)
        case 36, 76: onKey?(.confirm)
        case 53: onKey?(.cancel)
        default: super.keyDown(with: event)
        }
    }
}

private final class SwitcherCard: NSView {
    private let imageView = NSImageView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    // Two offset cards peeking behind the thumbnail to signal a grouped stack.
    private let deckBack = SwitcherCard.makeDeckLayer()
    private let deckFront = SwitcherCard.makeDeckLayer()
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 220).isActive = true
        heightAnchor.constraint(equalToConstant: 170).isActive = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Decks go behind the thumbnail, offset up and to the right.
        addSubview(deckBack)
        addSubview(deckFront)
        addSubview(imageView)
        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageView.heightAnchor.constraint(equalToConstant: 118),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            deckFront.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -4),
            deckFront.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 4),
            deckFront.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            deckFront.heightAnchor.constraint(equalTo: imageView.heightAnchor),
            deckBack.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -8),
            deckBack.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 8),
            deckBack.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            deckBack.heightAnchor.constraint(equalTo: imageView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private static func makeDeckLayer() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.55).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }

    func configure(with item: WindowEnumerator.Item) {
        if let thumb = item.thumbnail {
            imageView.image = NSImage(cgImage: thumb, size: .zero)
        } else {
            imageView.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        }
        iconView.image = item.appIcon

        let grouped = item.windowCount > 1
        deckFront.isHidden = !grouped
        deckBack.isHidden = !grouped
        // Grouped: show the app name and how many windows it stands for.
        titleLabel.stringValue = grouped ? "\(item.appName)  ·  \(item.windowCount)" : item.title
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.clear.cgColor
    }

    // Register the click on the first press even though it's a panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
