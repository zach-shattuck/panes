import AppKit
@preconcurrency import ScreenCaptureKit

/// Enumerates switchable windows on the current Space and captures a thumbnail
/// for each, via public ScreenCaptureKit only. Shared by the window switcher
/// and Snap Assist (both need "the other windows" with previews), so it lives
/// in core. Needs Screen Recording; without it `enumerate()` returns empty.
@MainActor
public final class WindowEnumerator {
    public struct Item {
        public let title: String
        public let appName: String
        public let appIcon: NSImage?
        public let pid: pid_t
        public let frame: CGRect // CG top-left
        public let thumbnail: CGImage?
        /// How many windows this card stands for when grouping by app (1 when
        /// not grouped). Drives the stacked look and the count label.
        public var windowCount: Int = 1
    }

    public init() {}

    /// Pre-warm the slow first SCShareableContent round-trip.
    public func prewarm() {
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    public func enumerate(maxThumbnailWidth: Int = 320) async -> [Item] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return [] }

        // Layer 0, on-screen, real titled windows of regular apps — the same
        // set Cmd-Tab-style switchers show.
        let windows = content.windows.filter { window in
            window.windowLayer == 0
                && window.isOnScreen
                && (window.title?.isEmpty == false)
                && window.frame.width > 80 && window.frame.height > 80
                && window.owningApplication?.applicationName.isEmpty == false
        }

        var items: [Item] = []
        for window in windows {
            guard let owner = window.owningApplication else { continue }
            let running = NSRunningApplication(processIdentifier: owner.processID)
            guard running?.activationPolicy == NSApplication.ActivationPolicy.regular else { continue }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = Double(maxThumbnailWidth) / window.frame.width
            config.width = min(maxThumbnailWidth, Int(window.frame.width))
            config.height = Int(window.frame.height * min(scale, 1.0))
            config.showsCursor = false
            config.scalesToFit = true

            let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            items.append(Item(
                title: window.title ?? owner.applicationName,
                appName: owner.applicationName,
                appIcon: running?.icon,
                pid: owner.processID,
                frame: window.frame,
                thumbnail: image
            ))
        }
        return items
    }

    /// Resolve the AX window that matches an enumerated item: by title, then by
    /// frame proximity (there is no public SCWindow↔AXUIElement bridge).
    public func axWindow(for item: Item) -> AXWindow? {
        let windows = AXWindow.windows(of: item.pid)
        return windows.first { $0.title == item.title && !item.title.isEmpty }
            ?? windows.min { distance($0.frame, item.frame) < distance($1.frame, item.frame) }
    }

    /// Raise the chosen window: match it to an AX window, de-minimize, and
    /// raise + activate.
    public func raise(_ item: Item) {
        if let match = axWindow(for: item) {
            if match.isMinimized { match.setMinimized(false) }
            match.raise()
        } else {
            NSRunningApplication(processIdentifier: item.pid)?.activate()
        }
    }

    private func distance(_ a: CGRect?, _ b: CGRect) -> CGFloat {
        guard let a else { return .greatestFiniteMagnitude }
        return abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }
}
