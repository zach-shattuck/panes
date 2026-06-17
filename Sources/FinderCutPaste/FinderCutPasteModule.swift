import AppKit
import Carbon.HIToolbox
import PanesCore
import os

/// Windows-style Cut/Paste for files in Finder.
///
/// macOS Finder can move a file (Edit ▸ Move Item Here = Cmd+Option+V) but
/// has no "cut" — there's no Cmd+X. This module supplies the muscle memory:
///   • Cmd+X in Finder  → copy the selection (Cmd+C) and arm a pending move
///   • Cmd+V in Finder  → if a move is armed, paste-as-move (Cmd+Option+V);
///                         otherwise pass the normal paste through
///
/// Mechanics: an active (consuming) event tap swallows the real Cmd+X / Cmd+V
/// and posts the substitute chord. Synthesized events are stamped with a
/// magic value on `.eventSourceUserData` so the tap ignores its own posts and
/// never loops. Key codes are layout-aware via `KeyboardLayout`.
public final class FinderCutPasteModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "finder-cut-paste",
        displayName: "Finder Cut & Paste",
        category: "Finder",
        summary: "Adds real cut and paste for files in Finder, so pasting moves them instead of leaving a copy behind.",
        howToUse: "In Finder, select some files and press ⌘X to cut them, then open the folder you want and press ⌘V to move them there instead of copying. A normal ⌘V still copies when you haven't cut anything.",
        requiredPermissions: [.accessibility]
    )

    private static let finderBundleID = "com.apple.finder"
    /// Stamped on our synthesized events so we don't re-intercept them.
    private static let syntheticTag: Int64 = 0x50_41_4E_58 // "PANX"

    private var tapToken: EventTapHub.Token?
    private weak var eventTaps: EventTapHub?
    /// Set when the user cuts; cleared on the next paste or when the
    /// pasteboard changes underneath us (a different copy invalidates the cut).
    private var pendingMoveChangeCount: Int?
    private let log = Logger.panes("finder-cut-paste")

    public init() {}

    public func start(context: ModuleContext) {
        eventTaps = context.eventTaps
        tapToken = context.eventTaps.subscribe(
            to: [.keyDown],
            wantsConsume: true
        ) { [weak self] _, event in
            self?.handleKey(event) ?? .pass
        }
    }

    public func stop() {
        if let token = tapToken { eventTaps?.unsubscribe(token) }
        tapToken = nil
        pendingMoveChangeCount = nil
    }

    private func handleKey(_ event: CGEvent) -> EventTapHub.Verdict {
        // Ignore our own synthesized chords.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticTag else {
            return .pass
        }
        // Only Cmd (no extra modifiers) shortcuts in Finder concern us.
        let flags = event.flags
        guard flags.contains(.maskCommand),
              !flags.contains(.maskShift),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else { return .pass }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleID else {
            return .pass
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let xCode = KeyboardLayout.shared.keyCode(for: "x") ?? CGKeyCode(kVK_ANSI_X)
        let cCode = KeyboardLayout.shared.keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C)
        let vCode = KeyboardLayout.shared.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)

        switch keyCode {
        case xCode:
            // "Cut" = copy now, remember that the NEXT paste should move.
            post(keyCode: cCode, flags: .maskCommand)
            // Finder's copy bumps the pasteboard; remember that count so a
            // later unrelated copy cancels the move.
            pendingMoveChangeCount = NSPasteboard.general.changeCount + 1
            log.debug("Finder cut armed")
            return .consume

        case vCode:
            if let armed = pendingMoveChangeCount, armed == NSPasteboard.general.changeCount {
                // Paste-as-move.
                post(keyCode: vCode, flags: [.maskCommand, .maskAlternate])
                pendingMoveChangeCount = nil
                log.debug("Finder paste-as-move")
                return .consume
            }
            // No armed cut (or pasteboard changed) → normal paste.
            return .pass

        default:
            return .pass
        }
    }

    private func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: isDown
            ) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
