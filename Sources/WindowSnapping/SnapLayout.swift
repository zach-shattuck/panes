import AppKit

/// A snap layout option as shown in the palette: a set of zones in
/// normalized layout space (origin top-left, 0–1 on both axes, mirroring how
/// Windows 11 draws its snap layouts).
struct SnapLayoutOption {
    let zones: [CGRect]

    /// The Windows 11 default set, minus the ultrawide-only entries.
    static let palette: [SnapLayoutOption] = [
        SnapLayoutOption(zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 1),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
        ]),
        SnapLayoutOption(zones: [
            CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1),
            CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1),
        ]),
        SnapLayoutOption(zones: [
            CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1),
            CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1),
            CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1),
        ]),
        SnapLayoutOption(zones: [
            CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ]),
    ]

    /// Resolve a normalized zone against a screen's usable area (visibleFrame
    /// already excludes menu bar and Dock). Returns AppKit coordinates.
    @MainActor
    static func frame(for zone: CGRect, on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        return NSRect(
            x: area.minX + zone.minX * area.width,
            // Layout space is top-down; AppKit is bottom-up.
            y: area.maxY - (zone.minY + zone.height) * area.height,
            width: zone.width * area.width,
            height: zone.height * area.height
        )
    }
}
