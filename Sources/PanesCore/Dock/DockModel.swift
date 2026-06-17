import AppKit
import ApplicationServices
import os

/// Shared model of the macOS Dock's icon geometry, read via the Dock
/// process's accessibility tree. Used by both DockPreviews (hover) and
/// DockComfort (click interception), which is why it lives in core.
///
/// Layout of the Dock's AX tree (stable across macOS 12–26, but treat
/// defensively — it is not API):
///   AXApplication (com.apple.dock)
///     └─ AXList ("Dock")
///         ├─ AXDockItem subrole "AXApplicationDockItem"  (app icons)
///         ├─ AXDockItem subrole "AXFolderDockItem" / "AXFileDockItem" …
///         ├─ AXDockItem subrole "AXMinimizedWindowDockItem"
///         └─ AXDockItem subrole "AXTrashDockItem"
///
/// Item frames are CG top-left global coordinates and update live during
/// dock magnification and auto-hide animation, so geometry is re-read with a
/// short TTL cache rather than persisted.
@MainActor
public final class DockModel {
    public struct Item {
        public let element: AXElement
        public let title: String?
        public let subrole: String?
        /// CG top-left global coordinates.
        public let frame: CGRect
        public let bundleURL: URL?
        /// For application items: whether the app is running (the "dot").
        public let isRunning: Bool

        public var isApplication: Bool { subrole == "AXApplicationDockItem" }
    }

    /// "AXIsApplicationRunning" — undocumented but long-stable attribute on
    /// application dock items.
    private static let isRunningAttribute = "AXIsApplicationRunning"

    private let log = Logger.panes("dock")
    private var cache: (items: [Item], at: ContinuousClock.Instant)?
    private let cacheTTL: Duration = .milliseconds(250)
    private var frameCache: (rect: CGRect, at: ContinuousClock.Instant)?
    // Short TTL: with Dock auto-hide the frame changes as the Dock slides in
    // and out, and a stale frame mis-positions previews on top of the Dock.
    private let frameCacheTTL: Duration = .milliseconds(250)

    public init() {}

    /// Set by DockPreviews while a scroll is steering a window selection, so
    /// DockComfort's click-to-minimize stands down and the same click commits
    /// the highlighted window instead. Cleared when the preview is dismissed.
    public var suppressClickMinimize = false

    public var dockPID: pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first?
            .processIdentifier
    }

    /// All dock items, cached briefly (geometry churns during magnification).
    public func items() -> [Item] {
        let now = ContinuousClock.now
        if let cache, now - cache.at < cacheTTL {
            return cache.items
        }
        let items = readItems()
        cache = (items, now)
        return items
    }

    public func applicationItems() -> [Item] {
        items().filter(\.isApplication)
    }

    /// Hit test in CG top-left coordinates. Uses the Dock's own AX hit
    /// testing (exact, magnification-aware) and falls back to cached frames.
    public func item(atCGPoint point: CGPoint) -> Item? {
        if let pid = dockPID {
            let dockApp = AXElement.application(pid: pid)
            if var element = dockApp.elementAtPosition(point) {
                var hops = 0
                while element.role != "AXDockItem", let parent = element.parent, hops < 5 {
                    element = parent
                    hops += 1
                }
                if element.role == "AXDockItem" {
                    return makeItem(from: element)
                }
            }
        }
        return items().first { $0.frame.contains(point) }
    }

    /// The Dock's AXList element — the parent of all dock items and the
    /// element that vends kAXSelectedChildrenChangedNotification (the
    /// hover signal).
    public func listElement() -> AXElement? {
        guard let pid = dockPID else { return nil }
        return AXElement.application(pid: pid)
            .children
            .first { $0.role == kAXListRole }
    }

    /// The item the Dock currently shows as hovered/selected, if any.
    /// (When the cursor is over the Dock, the Dock marks that item as the
    /// list's selected child.)
    public func selectedItem() -> Item? {
        guard let list = listElement() else { return nil }
        return list.elements(kAXSelectedChildrenAttribute).first.flatMap(makeItem(from:))
    }

    /// Which screen edge the Dock is on — drives where previews are placed so
    /// they never overlap the icons.
    public enum Edge: Sendable { case bottom, left, right }

    public func edge() -> Edge {
        guard let frame = dockFrame() else { return .bottom }
        // A bottom (or top) Dock is wider than tall; a side Dock is tall and
        // narrow.
        if frame.width >= frame.height { return .bottom }
        if let screen = ScreenGeometry.screen(containingCGPoint: CGPoint(x: frame.midX, y: frame.midY)) {
            let screenCG = ScreenGeometry.cgRect(fromAppKit: screen.frame)
            return frame.midX < screenCG.midX ? .left : .right
        }
        return frame.minX < 120 ? .left : .right
    }

    /// Bounding box of the dock list (CG coordinates), if visible. Cached
    /// with a TTL because this sits on DockComfort's per-click fast path —
    /// callers needing magnification-safe containment should inset the
    /// result generously (item hit tests stay exact via AX).
    public func dockFrame() -> CGRect? {
        let now = ContinuousClock.now
        if let frameCache, now - frameCache.at < frameCacheTTL {
            return frameCache.rect
        }
        guard let rect = listElement()?.frame else { return nil }
        frameCache = (rect, now)
        return rect
    }

    /// Resolve an application dock item to its running app, preferring the
    /// bundle URL (titles are localized and ambiguous).
    public func runningApplication(for item: Item) -> NSRunningApplication? {
        if let url = item.bundleURL {
            // kAXURLAttribute on dock items points at the app bundle.
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
            }) {
                return app
            }
        }
        guard let title = item.title else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == title }
    }

    // MARK: Reading

    private func readItems() -> [Item] {
        guard let pid = dockPID else {
            log.error("Dock process not found")
            return []
        }
        let dockApp = AXElement.application(pid: pid)
        guard let list = dockApp.children.first(where: { $0.role == kAXListRole }) else {
            return []
        }
        return list.children.compactMap(makeItem(from:))
    }

    private func makeItem(from element: AXElement) -> Item? {
        guard let frame = element.frame else { return nil }
        return Item(
            element: element,
            title: element.title,
            subrole: element.subrole,
            frame: frame,
            bundleURL: element.url(kAXURLAttribute),
            isRunning: element.bool(Self.isRunningAttribute) ?? false
        )
    }
}
