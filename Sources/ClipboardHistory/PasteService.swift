import AppKit
import Carbon.HIToolbox
import PanesCore

@MainActor
enum PasteService {
    /// Marks pasteboard writes that came from our own history so the
    /// watcher doesn't re-record them.
    nonisolated static let pasteBackMarker = NSPasteboard.PasteboardType("dev.panes.paste-back")

    /// Put the item back on the pasteboard and, when we're allowed to,
    /// synthesize Cmd+V into the still-focused app. Event synthesis needs
    /// Accessibility; without it this degrades gracefully to copy-only and
    /// the user pastes manually.
    static func paste(_ item: ClipboardItem, permissions: PermissionsManager) {
        write(item, to: .general)

        guard permissions.isGranted(.accessibility) else { return }
        // Tiny delay lets our (nonactivating) panel order out so the
        // keystroke lands in the app that kept focus the whole time.
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            synthesizeCmdV()
        }
    }

    /// Strip the current clipboard to plain text and paste it, regardless of
    /// whether the frontmost app offers "Paste and Match Style". Replaces the
    /// clipboard with the plain version (so a follow-up ⌘V stays plain too).
    /// Needs Accessibility to auto-paste; otherwise it just makes the clipboard
    /// plain and the user pastes manually.
    static func pasteCurrentAsPlainText(permissions: PermissionsManager) {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard permissions.isGranted(.accessibility) else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            synthesizeCmdV()
        }
    }

    /// Make the chosen item the current clipboard contents, tagged with our
    /// paste-back marker so the watcher won't re-record it. Because it stays on
    /// the clipboard, a later plain ⌘V keeps pasting it until something new is
    /// copied or chosen — matching the Windows clipboard-history behavior.
    static func write(_ item: ClipboardItem, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            // Marker on the same item as the text, so content and tag travel
            // together and the content is unambiguously the clipboard.
            let entry = NSPasteboardItem()
            entry.setString(item.text ?? "", forType: .string)
            entry.setString("Panes", forType: Self.pasteBackMarker)
            pasteboard.writeObjects([entry])
        case .fileList:
            var objects: [NSPasteboardWriting] = (item.text ?? "")
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) as NSURL }
            objects.append(markerItem())
            pasteboard.writeObjects(objects)
        case .image:
            var objects: [NSPasteboardWriting] = []
            if let data = item.data, let image = NSImage(data: data) { objects.append(image) }
            objects.append(markerItem())
            pasteboard.writeObjects(objects)
        }
    }

    private static func markerItem() -> NSPasteboardItem {
        let marker = NSPasteboardItem()
        marker.setString("Panes", forType: Self.pasteBackMarker)
        return marker
    }

    private static func synthesizeCmdV() {
        // Layout-aware: find the physical key that types "v" on the active
        // layout (kVK_ANSI_V is positional and wrong on AZERTY/Dvorak/etc.).
        // Fall back to the ANSI position if the layout can't be read.
        let keyCode = KeyboardLayout.shared.keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
