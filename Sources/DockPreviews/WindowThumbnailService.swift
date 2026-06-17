import AppKit
@preconcurrency import ScreenCaptureKit
import ApplicationServices
import PanesCore

/// Builds the window list + thumbnails for a Dock-hovered app.
///
/// Primary source is ACCESSIBILITY (the app's real windows), so SCK's phantom
/// helper surfaces don't create empty "ghost" cards, and we get the AXWindow
/// for the per-card close/minimize/full-screen/raise buttons. SCK is used to
/// paint pixels via one-shot SCScreenshotManager captures.
///
/// Robustness: some apps under-report through AX, so if AX yields no usable
/// windows we fall back to SCK's real on-screen windows (filtered to titled,
/// sized windows to keep ghosts out). `axWindow` is therefore optional — the
/// module degrades window actions gracefully when AX can't supply one.
@MainActor
public final class WindowThumbnailService {
    public struct Thumbnail {
        public let id = UUID()
        public let title: String
        public let axWindow: AXWindow?
        public let image: CGImage?
        public let isMinimized: Bool
    }

    private var contentCache: (content: SCShareableContent, at: ContinuousClock.Instant)?
    // Short TTL: a stale window list yields stale SCWindow references that
    // fail to capture. Fresh-per-hover is what makes previews reliable.
    private let contentTTL: Duration = .milliseconds(300)

    // Last good capture per window (keyed by pid + title), so a window that
    // can't be captured right now — minimized, off screen, or a transient
    // failure — still shows its most recent thumbnail instead of vanishing.
    // Refreshed whenever a live capture succeeds.
    private var imageCache: [String: CGImage] = [:]
    private var imageCacheOrder: [String] = []
    private let imageCacheLimit = 64

    public init() {}

    public func prewarm() {
        Task { _ = try? await shareableContent() }
    }

    public func thumbnails(for app: NSRunningApplication, maxPixelWidth: Int = 520) async -> [Thumbnail] {
        let pid = app.processIdentifier
        let scWindows = (try? await shareableContent())?.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        } ?? []

        let axWindows = AXWindow.windows(of: pid).filter(isPreviewable)

        // Preferred path: AX windows are the real, ghost-free list. Match
        // each AX window to a DISTINCT SCK window (consume the pool) so two
        // windows of the same app never share a thumbnail.
        if !axWindows.isEmpty {
            var pool = scWindows
            var result: [Thumbnail] = []
            for ax in axWindows {
                let windowTitle = title(of: ax, app: app)
                let key = "\(pid):\(windowTitle)"
                // Capture whenever ScreenCaptureKit actually sees this window
                // on screen — do NOT gate on AX's minimized flag, which some
                // apps (Music and other Catalyst apps) report incorrectly.
                var image: CGImage?
                if let match = takeMatch(for: ax, from: &pool), match.isOnScreen {
                    image = await capture(match, maxPixelWidth: maxPixelWidth)
                }
                // A window that can't be captured right now (minimized, off
                // screen, transient failure) keeps its last thumbnail; a live
                // capture refreshes it.
                if let image {
                    rememberImage(image, for: key)
                } else {
                    image = cachedImage(for: key)
                }
                result.append(Thumbnail(
                    title: windowTitle,
                    axWindow: ax,
                    image: image,
                    isMinimized: ax.isMinimized
                ))
            }
            return result
        }

        // Fallback: AX under-reported (happens for some apps). Use SCK's own
        // on-screen windows, filtered to real titled windows to avoid ghosts.
        var result: [Thumbnail] = []
        for sc in scWindows
        where sc.isOnScreen && (sc.title?.isEmpty == false) && sc.frame.width > 80 && sc.frame.height > 80 {
            let image = await capture(sc, maxPixelWidth: maxPixelWidth)
            result.append(Thumbnail(
                title: sc.title ?? app.localizedName ?? "Window",
                axWindow: axMatch(for: sc, pid: pid),
                image: image,
                isMinimized: false
            ))
        }
        return result
    }

    // MARK: Window selection

    /// Include real windows (standard/dialog, or a titled window with no
    /// subrole), exclude transient surfaces (sheets, popovers, floating
    /// palettes). Looser than a strict `isStandard` check so native apps
    /// (Messages, Music, Finder) and Catalyst apps preview correctly.
    private func isPreviewable(_ window: AXWindow) -> Bool {
        // A minimized window reports no meaningful on-screen frame, but it's
        // still a real window the user expects to see (and click to restore),
        // so keep it regardless of its reported size.
        if window.isMinimized { return isRealWindow(window) }
        guard let frame = window.frame, frame.width > 80, frame.height > 80 else { return false }
        return isRealWindow(window)
    }

    private func isRealWindow(_ window: AXWindow) -> Bool {
        switch window.subrole {
        case kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole:
            return true
        case nil:
            return window.title?.isEmpty == false
        default:
            return false
        }
    }

    private func rememberImage(_ image: CGImage, for key: String) {
        imageCacheOrder.removeAll { $0 == key }
        imageCacheOrder.append(key)
        imageCache[key] = image
        while imageCacheOrder.count > imageCacheLimit {
            imageCache[imageCacheOrder.removeFirst()] = nil
        }
    }

    private func cachedImage(for key: String) -> CGImage? {
        guard let image = imageCache[key] else { return nil }
        imageCacheOrder.removeAll { $0 == key }
        imageCacheOrder.append(key)
        return image
    }

    private func title(of window: AXWindow, app: NSRunningApplication) -> String {
        if let t = window.title, !t.isEmpty { return t }
        return app.localizedName ?? "Window"
    }

    // MARK: SC ⟷ AX matching + capture

    /// Remove and return the SCK window that best corresponds to `ax`,
    /// preferring an exact frame match, then a unique title match, then the
    /// nearest frame. Consuming the pool guarantees 1:1 assignment so distinct
    /// windows get distinct thumbnails.
    private func takeMatch(for ax: AXWindow, from pool: inout [SCWindow]) -> SCWindow? {
        guard !pool.isEmpty else { return nil }
        let axFrame = ax.frame
        // Exact frame match (most reliable for same-app windows).
        if let axFrame, let idx = pool.firstIndex(where: { $0.frame == axFrame }) {
            return pool.remove(at: idx)
        }
        // Unique title match.
        if let axTitle = ax.title, !axTitle.isEmpty {
            let matches = pool.indices.filter { pool[$0].title == axTitle }
            if matches.count == 1 { return pool.remove(at: matches[0]) }
        }
        // Nearest frame, but only when it's genuinely close — so an off-screen
        // (minimized) AX window can't steal a distant on-screen window's match.
        if let axFrame,
           let idx = pool.indices.min(by: { frameDistance(pool[$0].frame, axFrame) < frameDistance(pool[$1].frame, axFrame) }),
           frameDistance(pool[idx].frame, axFrame) < 240 {
            return pool.remove(at: idx)
        }
        return nil
    }

    private func axMatch(for sc: SCWindow, pid: pid_t) -> AXWindow? {
        let windows = AXWindow.windows(of: pid)
        if let title = sc.title, !title.isEmpty, let byTitle = windows.first(where: { $0.title == title }) {
            return byTitle
        }
        return windows.min { frameDistance($0.frame ?? .zero, sc.frame) < frameDistance($1.frame ?? .zero, sc.frame) }
    }

    private func capture(_ window: SCWindow, maxPixelWidth: Int) async -> CGImage? {
        guard window.frame.width > 1 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = min(Double(maxPixelWidth) / window.frame.width, 1.0)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        config.scalesToFit = true
        // One-shot captures occasionally fail transiently; a quick retry makes
        // it land reliably.
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(45)) }
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                return image
            }
        }
        return nil
    }

    private func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private func shareableContent() async throws -> SCShareableContent {
        if let cache = contentCache, ContinuousClock.now - cache.at < contentTTL {
            return cache.content
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        contentCache = (content, ContinuousClock.now)
        return content
    }

    public func invalidate() {
        contentCache = nil
    }
}
