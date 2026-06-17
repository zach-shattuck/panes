import AppKit

/// Base class for every floating overlay in the app (snap layout palette,
/// dock previews, freeze-frame screenshot surface, clipboard history).
///
/// The configuration that matters:
///  - `.nonactivatingPanel`: showing the overlay must NOT activate Panes —
///    snapping/previews happen while another app keeps focus, and stealing
///    key focus mid-drag would cancel the user's drag.
///  - `.canJoinAllSpaces` + `.fullScreenAuxiliary`: visible on every Space
///    and above full-screen apps.
///  - `level` defaults to `.statusBar`, above normal windows and the Dock;
///    the freeze-frame overlay raises this further (`.screenSaver`) to cover
///    the menu bar.
open class OverlayPanel: NSPanel {
    public init(level: NSWindow.Level = .statusBar) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.level = level
    }

    /// Borderless windows refuse key status by default; overlays that handle
    /// ESC/typing (freeze-frame, clipboard search) need it.
    open override var canBecomeKey: Bool { true }
    open override var canBecomeMain: Bool { false }
}
