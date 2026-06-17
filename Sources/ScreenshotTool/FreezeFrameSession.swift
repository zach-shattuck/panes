import AppKit
import PanesCore

/// One freeze-frame interaction: shows the frozen still of every display in
/// a screen-saver-level overlay, lets the user rubber-band a region on any of
/// them, crops, copies, and tears down. Order of operations is the whole
/// trick — capture happens in CaptureService BEFORE these windows exist.
@MainActor
final class FreezeFrameSession {
    private var windows: [FreezeFrameWindow] = []
    private let onFinish: (CGImage?) -> Void
    private var escMonitor: Any?

    init(captures: [CaptureService.DisplayCapture], onFinish: @escaping (CGImage?) -> Void) {
        self.onFinish = onFinish
        for capture in captures {
            let window = FreezeFrameWindow(capture: capture) { [weak self] result in
                self?.finish(with: result)
            }
            windows.append(window)
        }
        for window in windows {
            window.orderFrontRegardless()
        }
        // Key status goes to the display the cursor is on so per-view ESC
        // works there; the local monitor below covers ESC pressed while a
        // DIFFERENT display's overlay happens to be key.
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.screenFrame.contains(mouse) } ?? windows.first
        target?.makeKey()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // ESC
            self?.finish(with: nil)
            return nil
        }
        NSCursor.crosshair.push()
    }

    /// Abort (module stop, app quit) — tears down windows and rebalances
    /// the cursor stack.
    func cancel() {
        guard !windows.isEmpty else { return }
        finish(with: nil)
    }

    private var didFinish = false

    private func finish(with image: CGImage?) {
        // ESC monitor and a completing selection can both land; only the
        // first wins.
        guard !didFinish else { return }
        didFinish = true
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
        NSCursor.pop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        onFinish(image)
    }
}

/// Full-screen overlay for a single display showing its frozen capture.
private final class FreezeFrameWindow: OverlayPanel {
    let screenFrame: NSRect

    init(capture: CaptureService.DisplayCapture, onComplete: @escaping (CGImage?) -> Void) {
        screenFrame = capture.screen.frame
        // .screenSaver sits above the menu bar and Dock — the freeze must
        // cover everything or the illusion breaks.
        super.init(level: .screenSaver)
        hasShadow = false
        setFrame(capture.screen.frame, display: false)
        let selection = SelectionView(image: capture.image, onComplete: onComplete)
        contentView = selection
        // Key status alone routes keys to the WINDOW; ESC handling lives in
        // the view, which must be first responder explicitly.
        makeFirstResponder(selection)
    }
}

/// Draws the frozen image, dims it, and rubber-bands a selection.
private final class SelectionView: NSView {
    private let image: CGImage
    private let onComplete: (CGImage?) -> Void
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(image: CGImage, onComplete: @escaping (CGImage?) -> Void) {
        self.image = image
        self.onComplete = onComplete
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }

    /// Selection can start on a display whose overlay is not the key
    /// window — deliver that first click instead of eating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onComplete(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let rect = selectionRect, rect.width > 3, rect.height > 3 else {
            needsDisplay = true
            return
        }
        onComplete(crop(to: rect))
    }

    private var selectionRect: NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }

    /// View points (bottom-left origin) -> image pixels (top-left origin).
    private func crop(to rect: NSRect) -> CGImage? {
        let scaleX = CGFloat(image.width) / bounds.width
        let scaleY = CGFloat(image.height) / bounds.height
        let pixelRect = CGRect(
            x: rect.minX * scaleX,
            y: CGFloat(image.height) - rect.maxY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
        return image.cropping(to: pixelRect.integral)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The frozen still.
        context.draw(image, in: bounds)

        // Dim everything outside the live selection.
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        if let selection = selectionRect {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(selection)
            context.clip(using: .evenOdd)
            context.fill(bounds)
            context.restoreGState()

            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1)
            context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
        } else {
            context.fill(bounds)
        }
    }
}
