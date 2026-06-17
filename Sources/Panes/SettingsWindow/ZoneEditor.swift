import AppKit
import PanesCore
import WindowSnapping

/// Freeform canvas for designing a snap layout: drag on empty space to create
/// a zone, drag a zone to move it, drag its handles to resize, Delete to remove
/// the selected one. Zones live in normalized layout space (0–1, top-left
/// origin) so they map straight onto any screen. Coordinates are kept simple by
/// making the view flipped (top-left origin, like the layout space itself).
final class ZoneEditorView: NSView {
    private var zones: [CGRect]
    private var selected: Int?
    private var draft: CGRect?

    private enum Drag {
        case none
        case creating(anchor: CGPoint)
        case moving(start: CGRect, grab: CGPoint)
        case resizing(start: CGRect, hx: Int, hy: Int)
    }
    private var drag: Drag = .none

    /// Fired whenever the zone set changes, so the window can enable/disable Save.
    var onChange: (() -> Void)?

    private let minSize: CGFloat = 0.1
    private let gridSteps: CGFloat = 60 // snap to 1/60 so halves/thirds/quarters land exactly
    private let handleSize: CGFloat = 11

    /// Full-screen mode: thin margins and a transparent background (the overlay
    /// window supplies the dim), so the canvas reads as the real screen.
    var fullBleed = false { didSet { needsDisplay = true } }
    private var margin: CGFloat { fullBleed ? 12 : 18 }

    init(zones: [CGRect]) {
        self.zones = zones
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var normalizedZones: [CGRect] { zones }
    var isEmpty: Bool { zones.isEmpty }

    func deleteSelected() {
        guard let index = selected, zones.indices.contains(index) else { return }
        zones.remove(at: index)
        selected = nil
        needsDisplay = true
        onChange?()
    }

    // MARK: Coordinate mapping

    private var canvas: CGRect { bounds.insetBy(dx: margin, dy: margin) }

    private func toNorm(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - canvas.minX) / canvas.width, y: (point.y - canvas.minY) / canvas.height)
    }

    private func viewRect(_ zone: CGRect) -> CGRect {
        CGRect(
            x: canvas.minX + zone.minX * canvas.width,
            y: canvas.minY + zone.minY * canvas.height,
            width: zone.width * canvas.width,
            height: zone.height * canvas.height
        )
    }

    private func snapClamp(_ value: CGFloat) -> CGFloat {
        min(max((value * gridSteps).rounded() / gridSteps, 0), 1)
    }

    /// Center of a resize handle (view coords) for the given zone and handle.
    private func handleCenter(_ zone: CGRect, _ hx: Int, _ hy: Int) -> CGPoint {
        let rect = viewRect(zone)
        return CGPoint(
            x: rect.minX + CGFloat(hx + 1) / 2 * rect.width,
            y: rect.minY + CGFloat(hy + 1) / 2 * rect.height
        )
    }

    private static let handles: [(Int, Int)] = [
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    ]

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        // A handle of the selected zone takes priority.
        if let index = selected, zones.indices.contains(index) {
            for (hx, hy) in Self.handles {
                let center = handleCenter(zones[index], hx, hy)
                if CGRect(x: center.x - handleSize, y: center.y - handleSize,
                          width: handleSize * 2, height: handleSize * 2).contains(point) {
                    drag = .resizing(start: zones[index], hx: hx, hy: hy)
                    return
                }
            }
        }

        // Topmost zone under the cursor (drawn last = on top).
        if let index = zones.lastIndex(where: { viewRect($0).contains(point) }) {
            selected = index
            let grab = toNorm(point)
            drag = .moving(start: zones[index], grab: grab)
            needsDisplay = true
            return
        }

        // Empty space: start drawing a new zone.
        let anchor = CGPoint(x: snapClamp(toNorm(point).x), y: snapClamp(toNorm(point).y))
        drag = .creating(anchor: anchor)
        selected = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let norm = toNorm(point)
        switch drag {
        case .none:
            break
        case .creating(let anchor):
            let b = CGPoint(x: snapClamp(norm.x), y: snapClamp(norm.y))
            draft = CGRect(x: min(anchor.x, b.x), y: min(anchor.y, b.y),
                           width: abs(b.x - anchor.x), height: abs(b.y - anchor.y))
            needsDisplay = true
        case .moving(let start, let grab):
            guard let index = selected else { return }
            let dx = norm.x - grab.x
            let dy = norm.y - grab.y
            let x = min(max(snapClamp(start.minX + dx), 0), 1 - start.width)
            let y = min(max(snapClamp(start.minY + dy), 0), 1 - start.height)
            zones[index] = CGRect(x: x, y: y, width: start.width, height: start.height)
            needsDisplay = true
        case .resizing(let start, let hx, let hy):
            guard let index = selected else { return }
            zones[index] = resized(start, hx: hx, hy: hy, to: norm)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating = drag, let rect = draft {
            if rect.width >= minSize, rect.height >= minSize {
                zones.append(rect)
                selected = zones.count - 1
                onChange?()
            }
        } else if case .moving = drag {
            onChange?()
        } else if case .resizing = drag {
            onChange?()
        }
        draft = nil
        drag = .none
        needsDisplay = true
    }

    /// Resize `start` by moving the edges the handle controls to `point`,
    /// keeping the opposite edge fixed and never shrinking below `minSize`.
    private func resized(_ start: CGRect, hx: Int, hy: Int, to point: CGPoint) -> CGRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY
        let px = snapClamp(point.x), py = snapClamp(point.y)
        if hx == -1 { minX = min(px, maxX - minSize) }
        if hx == 1 { maxX = max(px, minX + minSize) }
        if hy == -1 { minY = min(py, maxY - minSize) }
        if hy == 1 { maxY = max(py, minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete
            deleteSelected()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // In windowed mode draw the "screen" the zones sit on; in full-screen
        // mode the overlay window already dims the real screen behind us.
        if !fullBleed {
            let screen = NSBezierPath(roundedRect: canvas, xRadius: 8, yRadius: 8)
            NSColor.windowBackgroundColor.setFill()
            screen.fill()
        }

        // Faint guide grid (twelfths) to make clean splits easy to hit.
        (fullBleed ? NSColor.white.withAlphaComponent(0.12) : NSColor.separatorColor.withAlphaComponent(0.4)).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for i in 1..<12 {
            let fx = canvas.minX + CGFloat(i) / 12 * canvas.width
            grid.move(to: CGPoint(x: fx, y: canvas.minY)); grid.line(to: CGPoint(x: fx, y: canvas.maxY))
            let fy = canvas.minY + CGFloat(i) / 12 * canvas.height
            grid.move(to: CGPoint(x: canvas.minX, y: fy)); grid.line(to: CGPoint(x: canvas.maxX, y: fy))
        }
        grid.stroke()

        for (index, zone) in zones.enumerated() {
            let rect = viewRect(zone).insetBy(dx: 1.5, dy: 1.5)
            let isSelected = index == selected
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(isSelected ? 0.28 : 0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(isSelected ? 1 : 0.6).setStroke()
            path.lineWidth = isSelected ? 2 : 1
            path.stroke()

            let label = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)

            if isSelected {
                for (hx, hy) in Self.handles {
                    let center = handleCenter(zone, hx, hy)
                    let dot = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                    NSColor.controlAccentColor.setFill()
                    NSColor.white.setStroke()
                    let handlePath = NSBezierPath(roundedRect: dot, xRadius: 2, yRadius: 2)
                    handlePath.fill()
                    handlePath.lineWidth = 1
                    handlePath.stroke()
                }
            }
        }

        if let draft {
            let rect = viewRect(draft)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        if zones.isEmpty, draft == nil {
            let hint = "Drag to create a zone" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fullBleed ? 17 : 13, weight: fullBleed ? .medium : .regular),
                .foregroundColor: fullBleed ? NSColor.white.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor,
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: CGPoint(x: canvas.midX - size.width / 2, y: canvas.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

/// Borderless full-screen overlay that can take key/focus (for the name field
/// and the Delete key).
private final class EditorOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the freeform editor as a full-screen overlay: it dims the real screen
/// so the desktop becomes the canvas and zones are drawn at true scale. A small
/// floating bar carries the name field and Save / Cancel / Delete.
final class ZoneEditorWindowController: NSWindowController {
    var onSave: ((ZoneLayout) -> Void)?
    var onClose: (() -> Void)?

    private let editor: ZoneEditorView
    private let nameField = NSTextField()
    private let saveButton = NSButton()
    private let existingID: UUID?

    init(layout: ZoneLayout?) {
        existingID = layout?.id
        editor = ZoneEditorView(zones: layout?.zones.map(\.rect) ?? [])
        editor.fullBleed = true

        let window = EditorOverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        window.hasShadow = false
        window.level = .modalPanel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)

        nameField.stringValue = layout?.name ?? "Custom Layout"
        nameField.placeholderString = "Layout name"
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let deleteButton = NSButton(title: "Delete Zone", target: self, action: #selector(deleteZone))
        deleteButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc
        saveButton.title = "Save Layout"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)

        // Floating frosted control bar at the top center.
        let row = NSStackView(views: [nameField, deleteButton, cancelButton, saveButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
        ])

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.onChange = { [weak self] in self?.updateSaveEnabled() }

        let content = NSView()
        content.addSubview(editor)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
        window.contentView = content
        updateSaveEnabled()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Show the overlay covering `screen`'s work area (where windows snap), so
    /// the zones map one-to-one to where windows will land.
    func present(on screen: NSScreen?) {
        let target = screen ?? NSScreen.main
        if let frame = target?.visibleFrame {
            window?.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(editor)
        updateSaveEnabled()
    }

    private func updateSaveEnabled() {
        saveButton.isEnabled = !editor.isEmpty
    }

    @objc private func deleteZone() { editor.deleteSelected() }

    @objc private func save() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = ZoneLayout(
            id: existingID ?? UUID(),
            name: trimmed.isEmpty ? "Custom Layout" : trimmed,
            zones: editor.normalizedZones.map(ZoneLayout.Zone.init)
        )
        onSave?(layout)
        dismiss()
    }

    @objc private func cancel() { dismiss() }

    private func dismiss() {
        window?.orderOut(nil)
        onClose?()
    }
}
