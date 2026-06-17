import AppKit
// @preconcurrency: SCShareableContent is not Sendable but must cross the
// timeout-race task group; it's an immutable snapshot in practice.
@preconcurrency import ScreenCaptureKit
import PanesCore
import os

/// Display capture for the screenshot module.
@MainActor
final class CaptureService {
    struct DisplayCapture {
        let screen: NSScreen
        let image: CGImage
    }

    private let log = Logger.panes("screenshot")

    /// Standard mode: Apple's interactive picker (crosshair + window mode +
    /// Space bar toggling), straight to the clipboard. No permission is
    /// dodged by shelling out — TCC attributes the child to its "responsible
    /// process", which is Panes — but the native picker UI itself is worth
    /// having as the non-freeze mode.
    func standardInteractiveCapture() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-c", "-i"] // clipboard, interactive
        do {
            try process.run()
        } catch {
            log.error("screencapture launch failed: \(error)")
        }
    }

    /// Freeze-frame: one full-resolution still per display, captured BEFORE
    /// any overlay window exists so we never photograph our own UI.
    ///
    /// Upgrade path (not taken while the floor is macOS 14): macOS 15 adds
    /// HDR presets (`SCStreamConfiguration(preset: .captureHDRScreenshot…)`)
    /// and macOS 26 adds `SCScreenshotManager.captureScreenshot(rect:…)`
    /// with `SCScreenshotConfiguration`, which can skip SCShareableContent
    /// enumeration entirely.
    func captureAllDisplays() async -> [DisplayCapture] {
        guard let content = await shareableContent() else { return [] }

        var captures: [DisplayCapture] = []
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber,
                let display = content.displays.first(where: {
                    $0.displayID == CGDirectDisplayID(number.uint32Value)
                })
            else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            // Native pixel size so retina crops stay crisp — derived from
            // the filter itself (Apple's documented recipe), not NSScreen.
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.captureResolution = .best

            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            ) {
                captures.append(DisplayCapture(screen: screen, image: image))
            } else {
                log.error("display capture failed for \(screen.localizedName)")
            }
        }
        return captures
    }

    /// SCShareableContent is an XPC round-trip to replayd: slow on first
    /// call and able to hang outright when replayd is wedged — race a
    /// timeout and fail soft.
    private nonisolated func shareableContent() async -> SCShareableContent? {
        await withTaskGroup(of: SCShareableContent?.self) { group in
            group.addTask {
                try? await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func copyToClipboard(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Write a compressed PNG rather than the NSImage's TIFF: a full-screen
        // TIFF can be tens of MB, which overflows the clipboard-history capture
        // cap and the screenshot never lands in history.
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            pasteboard.writeObjects([item])
        } else {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            pasteboard.writeObjects([nsImage])
        }
    }
}
