import AppKit
import CoreImage

/// A light frosted backdrop with no border and soft, feathered edges that fade
/// into the desktop — used behind the cascade so the Dock's own app-name label
/// (and anything else behind the previews) is blurred away rather than bleeding
/// through the gaps between floating cards.
final class FrostedBackingView: NSView {
    private let effect = NSVisualEffectView()

    init(blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = blendingMode
        effect.state = .active
        effect.maskImage = Self.featherMask
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        effect.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        effect.frame = bounds
    }

    /// Rounded, feathered mask reused for every backing (it's resolution- and
    /// size-independent thanks to cap insets + stretch resizing).
    static let featherMask = featheredMaskImage(cornerRadius: 16, feather: 12)
}

/// A rounded-rectangle mask whose edges are blurred so the material fades out
/// softly instead of ending at a hard border. Cap insets keep the feathered
/// corners crisp while the center stretches to any size.
func featheredMaskImage(cornerRadius: CGFloat, feather: CGFloat) -> NSImage {
    let cap = cornerRadius + feather * 2
    let side = cap * 2 + 2
    let size = NSSize(width: side, height: side)

    let solid = NSImage(size: size)
    solid.lockFocus()
    NSColor.white.setFill()
    // Draw the solid core one feather-radius in, so after the blur the core
    // stays fully opaque and only the outer band fades — a soft halo.
    let inset = feather
    NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
        xRadius: cornerRadius, yRadius: cornerRadius
    ).fill()
    solid.unlockFocus()

    var result = solid
    if let tiff = solid.tiffRepresentation, let input = CIImage(data: tiff) {
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur?.setValue(feather, forKey: kCIInputRadiusKey)
        if let output = blur?.outputImage?.cropped(to: input.extent) {
            let blurred = NSImage(size: size)
            blurred.addRepresentation(NSCIImageRep(ciImage: output))
            result = blurred
        }
    }
    result.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    result.resizingMode = .stretch
    return result
}

/// A self-contained miniature of the Dock previews, shown in Settings so size,
/// background, and button-color changes are visible live as the user adjusts
/// them. Renders two sample cards over the chosen backing.
@MainActor
public final class DockPreviewSampleView: NSView {
    private let backing = FrostedBackingView(blendingMode: .withinWindow)
    private var cards: [ThumbnailCardView] = []
    private static let baseW: CGFloat = 150
    private static let baseH: CGFloat = 104
    private static let sample = sampleImage()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(backing)
    }

    public required init?(coder: NSCoder) { fatalError("unused") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 224) }

    public override var isFlipped: Bool { true }

    /// `scale` is the preview-size multiplier (0.7–1.6), matching the live
    /// previews; `frosted` shows/hides the backdrop; `monochrome` grays the
    /// window buttons.
    public func update(scale: CGFloat, frosted: Bool, monochrome: Bool) {
        backing.isHidden = !frosted

        cards.forEach { $0.removeFromSuperview() }
        let item = ClipboardThumbStub.thumbnail(image: Self.sample)
        cards = (0..<2).map { _ in
            let card = ThumbnailCardView(monochrome: monochrome)
            card.configure(with: item)
            card.applyFloatingShadow()
            addSubview(card)
            return card
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        layoutSample(scale: scale)
    }

    public override func layout() {
        super.layout()
        // Re-place with the last scale on resize; default to 1 if never set.
        layoutSample(scale: lastScale)
    }

    private var lastScale: CGFloat = 1

    private func layoutSample(scale: CGFloat) {
        lastScale = scale
        let w = (Self.baseW * scale).rounded()
        let h = (Self.baseH * scale).rounded()
        let step = h * 0.45            // overlap so the cascade reads as a stack
        let totalH = h + step
        let top = (bounds.height - totalH) / 2
        let x = (bounds.width - w) / 2
        for (i, card) in cards.enumerated() {
            // Front card lower/in-front; back card peeks above it.
            card.frame = NSRect(x: x, y: top + CGFloat(1 - i) * step, width: w, height: h)
        }
        // Backing extends past the cards so the solid frost reaches their edges
        // and the feather fades out beyond, like a soft halo.
        if !backing.isHidden {
            backing.frame = NSRect(x: x - 22, y: top - 20, width: w + 44, height: totalH + 40)
        }
    }
}

/// Builds a sample ClipboardItem-free Thumbnail for the settings miniature.
private enum ClipboardThumbStub {
    static func thumbnail(image: CGImage?) -> WindowThumbnailService.Thumbnail {
        WindowThumbnailService.Thumbnail(title: "Preview", axWindow: nil, image: image, isMinimized: false)
    }
}

/// A soft gradient that stands in for a real window capture in the miniature.
private func sampleImage() -> CGImage? {
    let width = 300
    let height = 200
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let colors = [
        NSColor.systemBlue.withAlphaComponent(0.55).cgColor,
        NSColor.systemTeal.withAlphaComponent(0.45).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height),
            end: CGPoint(x: width, y: 0),
            options: []
        )
    }
    return ctx.makeImage()
}
