import AppKit
import PanesCore

/// The shared surface the module drives, so it can swap between the
/// side-by-side row (`PreviewPanel`) and the stacked cascade (`CascadePanel`)
/// without caring which is on screen.
@MainActor
protocol PreviewSurface: AnyObject {
    var monochromeLights: Bool { get set }
    var previewScale: CGFloat { get set }
    var frostedBacking: Bool { get set }
    var onSelect: ((WindowThumbnailService.Thumbnail) -> Void)? { get set }
    var onClose: ((WindowThumbnailService.Thumbnail) -> Void)? { get set }
    var onMinimize: ((WindowThumbnailService.Thumbnail) -> Void)? { get set }
    var onFullScreen: ((WindowThumbnailService.Thumbnail) -> Void)? { get set }
    var isVisible: Bool { get }
    func show(thumbnails: [WindowThumbnailService.Thumbnail], anchor: CGRect, edge: DockModel.Edge, dockFrameCG: CGRect?)
    func hide()
    func frameCG() -> CGRect?
    /// Highlight the card at `index` (nil clears) as the scroll-to-pick
    /// selection; a stacked surface fans open so the choice is visible.
    func highlight(index: Int?)
}

extension PreviewPanel: PreviewSurface {}
extension CascadePanel: PreviewSurface {}
