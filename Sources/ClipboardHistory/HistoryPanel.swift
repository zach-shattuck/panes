import AppKit
import PanesCore

/// Windows-11-style clipboard history: a floating card list near the cursor.
/// Each entry renders its actual content — text snippet, image thumbnail, or
/// file list — and a single click pastes it into the app you were using.
///
/// Unlike the Dock previews (which must NOT steal focus), this panel activates
/// so you can type to search and arrow through entries. It remembers the app
/// that was frontmost and re-activates it when pasting, so paste-back still
/// lands in the right place.
@MainActor
final class HistoryPanel: NSObject, NSWindowDelegate {
    private let panel: OverlayPanel
    private let searchField = NSSearchField()
    private let listStack = FlippedStack()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No clipboard history yet")

    private var items: [ClipboardItem] = []
    private var cards: [HistoryCard] = []
    private var selectedIndex = 0
    private var previousApp: NSRunningApplication?
    private var shownAt = ContinuousClock.now
    private var currentQuery = ""

    var onChoose: ((ClipboardItem) -> Void)?
    var onQuery: ((String) -> [ClipboardItem])?
    /// Toggle the pinned state of an item; the panel reloads to re-sort.
    var onTogglePin: ((ClipboardItem) -> Void)?

    /// Fixed sizes so the panel stays small and content can't stretch it. The
    /// list fills the full width (the scrollers are overlay-style, so no need
    /// to reserve a gutter); the cards' own inset is the side padding, which
    /// keeps left and right even.
    private static let windowWidth: CGFloat = 280
    private static let contentWidth: CGFloat = 280

    override init() {
        panel = OverlayPanel(level: .floating)
        super.init()
        panel.delegate = self

        searchField.placeholderString = "Search clipboard"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.focusRingType = .none

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 10, right: 10)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = listStack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        let container = NSVisualEffectView()
        container.material = .menu
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // FIXED width, not tied to the scroll view: an NSScrollView derives
            // its intrinsic size from its document view, so coupling the two
            // lets a wide image card feed back and blow the window wide open.
            listStack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        panel.contentView = container
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if panel.isVisible { dismiss() } else { show() }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        searchField.stringValue = ""
        reload(query: "")

        let size = NSSize(width: Self.windowWidth, height: 440)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height + 10)
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
            origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        shownAt = ContinuousClock.now
        // orderFrontRegardless reliably shows the panel for a menu-bar
        // (accessory) app; makeKey then lets the search field take typing.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    /// Hide and return focus to the app the user came from.
    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        previousApp?.activate()
    }

    /// Order out without restoring focus (used on module stop and on
    /// click-outside, where another app is already taking focus).
    func hide() {
        panel.orderOut(nil)
    }

    // MARK: NSWindowDelegate — click-outside dismisses.

    func windowDidResignKey(_ notification: Notification) {
        // Ignore the brief race right after we activate/show.
        guard ContinuousClock.now - shownAt > .milliseconds(250) else { return }
        // The user clicked another app (which is now activating) — just close.
        hide()
    }

    // MARK: List

    private func reload(query: String) {
        currentQuery = query
        items = onQuery?(query) ?? []
        cards.forEach { $0.removeFromSuperview() }
        cards = items.enumerated().map { index, item in
            let card = HistoryCard(item: item)
            card.onClick = { [weak self] in self?.choose(index: index) }
            card.onPin = { [weak self] in self?.pin(index: index) }
            // Add to the stack BEFORE constraining width — the constraint
            // needs both views to share an ancestor or it silently fails.
            listStack.addArrangedSubview(card)
            card.widthConstraint(to: listStack, inset: 20)
            return card
        }
        emptyLabel.isHidden = !items.isEmpty
        selectedIndex = 0
        refreshSelection()
    }

    private func pin(index: Int) {
        guard items.indices.contains(index) else { return }
        onTogglePin?(items[index])
        reload(query: currentQuery)
    }

    private func choose(index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        panel.orderOut(nil)
        // Re-activate the app we came from, then paste into it.
        previousApp?.activate()
        let handler = onChoose
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            handler?(item)
        }
    }

    private func move(by delta: Int) {
        guard !cards.isEmpty else { return }
        selectedIndex = max(0, min(cards.count - 1, selectedIndex + delta))
        refreshSelection()
        let card = cards[selectedIndex]
        card.scrollToVisible(card.bounds)
    }

    private func refreshSelection() {
        for (i, card) in cards.enumerated() { card.setSelected(i == selectedIndex) }
    }
}

extension HistoryPanel: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(index: selectedIndex); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
}

/// One clipboard entry rendered with its real content.
private final class HistoryCard: NSView {
    let item: ClipboardItem
    var onClick: (() -> Void)?
    var onPin: (() -> Void)?
    private var selected = false
    private var hovered = false
    private let pinButton = NSButton()

    init(item: ClipboardItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        buildContent()
        addPinButton()
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func widthConstraint(to parent: NSView, inset: CGFloat) {
        widthAnchor.constraint(equalTo: parent.widthAnchor, constant: -inset).isActive = true
    }

    private func buildContent() {
        switch item.kind {
        case .text:
            // Show a compact preview only — collapse whitespace/newlines and
            // cap at ~90 chars so each row stays small. The FULL text is still
            // what gets pasted (item.text is untouched).
            let collapsed = (item.text ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let preview = collapsed.count > 90 ? String(collapsed.prefix(90)) + "…" : collapsed
            let label = NSTextField(wrappingLabelWithString: preview)
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.isEditable = false
            label.isSelectable = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                // Leave room for the pin button at the top-right.
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            ])

        case .image:
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 4
            imageView.layer?.masksToBounds = true
            if let data = item.data { imageView.image = NSImage(data: data) }
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                imageView.heightAnchor.constraint(equalToConstant: 92),
            ])

        case .fileList:
            let paths = (item.text ?? "").split(separator: "\n").map(String.init)
            let icon = NSImageView()
            icon.image = paths.first.map { NSWorkspace.shared.icon(forFile: $0) }
            icon.translatesAutoresizingMaskIntoConstraints = false
            let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let label = NSTextField(labelWithString: paths.count == 1 ? names : "\(paths.count) files: \(names)")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 44),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 22),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    /// A small pin toggle in the top-right: filled and accented when pinned,
    /// dim otherwise. The card is rebuilt on toggle, so this just reflects the
    /// current state at build time.
    private func addPinButton() {
        pinButton.imagePosition = .imageOnly
        pinButton.isBordered = false
        pinButton.setButtonType(.momentaryChange)
        pinButton.controlSize = .small
        pinButton.refusesFirstResponder = true
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        let symbol = item.pinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.pinned ? "Unpin" : "Pin")
        pinButton.contentTintColor = item.pinned ? .controlAccentColor : .tertiaryLabelColor
        pinButton.alphaValue = item.pinned ? 1.0 : 0.55
        pinButton.toolTip = item.pinned ? "Unpin" : "Pin to top"
        addSubview(pinButton)
        NSLayoutConstraint.activate([
            pinButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pinButton.widthAnchor.constraint(equalToConstant: 20),
            pinButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @objc private func pinClicked() { onPin?() }

    func setSelected(_ value: Bool) {
        selected = value
        updateBackground()
    }

    private func updateBackground() {
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        } else if hovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        }
    }

    // Single click pastes — first click registers even though it's a panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateBackground() }
}

/// Top-down document view for the scrolling card list.
private final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}
