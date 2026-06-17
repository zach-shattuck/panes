import AppKit
import PanesCore

/// Shows where a window will snap when dragged to a screen edge or corner
/// (Windows Aero Snap): a clean rounded outline over a faint frosted fill.
/// When it first appears it grows out fast from the cursor to the target, and
/// it slides/resizes when you move to a different zone. Purely visual.
@MainActor
final class SnapPreviewPanel {
    private let panel: OverlayPanel
    private var currentTarget: NSRect?

    init() {
        panel = OverlayPanel(level: .statusBar)
        panel.ignoresMouseEvents = true

        // Faint frosted fill, so the line isn't floating over nothing.
        let fill = NSVisualEffectView()
        fill.material = .hudWindow
        fill.blendingMode = .behindWindow
        fill.state = .active
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 14
        fill.layer?.masksToBounds = true
        fill.alphaValue = 0.3
        fill.translatesAutoresizingMaskIntoConstraints = false

        // The crisp outline, at full strength on top of the faint fill.
        let outline = NSView()
        outline.wantsLayer = true
        outline.layer?.cornerRadius = 14
        outline.layer?.borderWidth = 2
        outline.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        outline.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(fill)
        container.addSubview(outline)
        panel.contentView = container
        for view in [fill, outline] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// `rect` is the target frame in AppKit (bottom-left) coordinates.
    func show(appKitRect rect: NSRect) {
        let target = rect.insetBy(dx: 6, dy: 6)
        guard currentTarget != target else { return } // same zone, already shown
        let wasHidden = currentTarget == nil
        currentTarget = target

        if wasHidden {
            // Start as a small box at the cursor, then grow to the target.
            let mouse = NSEvent.mouseLocation
            panel.setFrame(NSRect(x: mouse.x - 40, y: mouse.y - 28, width: 80, height: 56), display: true)
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = wasHidden ? 0.16 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        currentTarget = nil
        panel.orderOut(nil)
    }
}
