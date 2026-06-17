import AppKit
import PanesCore
import WindowSnapping

/// Settings list of the user's custom snap layouts: a thumbnail and name per
/// layout with Edit / Delete, plus "New Layout…". Editing opens the freeform
/// `ZoneEditorWindowController` as a sheet. Saved layouts appear in the
/// drag-to-top snap palette automatically (the module reads them per drag).
final class CustomLayoutsView: NSStackView {
    private let preferences: PreferencesStore
    private var editorController: ZoneEditorWindowController?

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }

        let layouts = CustomLayoutStore.load(preferences)
        if layouts.isEmpty {
            let none = NSTextField(labelWithString: "No custom layouts yet.")
            none.font = .systemFont(ofSize: 11.5)
            none.textColor = .tertiaryLabelColor
            addArrangedSubview(none)
        } else {
            for layout in layouts {
                let row = layoutRow(layout)
                addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }

        let new = ClosureButton(title: "New Layout…") { [weak self] in self?.presentEditor(nil) }
        addArrangedSubview(new)
    }

    private func layoutRow(_ layout: ZoneLayout) -> NSView {
        let thumb = LayoutThumbView(layout: layout)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: 56).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let name = NSTextField(labelWithString: layout.name)
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let edit = ClosureButton(title: "Edit") { [weak self] in self?.presentEditor(layout) }
        let delete = ClosureButton(title: "Delete") { [weak self] in self?.delete(layout) }

        let row = NSStackView(views: [thumb, name, spacer, edit, delete])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func presentEditor(_ existing: ZoneLayout?) {
        let controller = ZoneEditorWindowController(layout: existing)
        controller.onSave = { [weak self] layout in self?.persist(layout) }
        controller.onClose = { [weak self] in
            self?.editorController = nil
            self?.rebuild()
        }
        editorController = controller
        // Edit on the screen the Settings window is on (falls back to main).
        controller.present(on: window?.screen)
    }

    private func persist(_ layout: ZoneLayout) {
        var layouts = CustomLayoutStore.load(preferences)
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
        CustomLayoutStore.save(layouts, preferences)
    }

    private func delete(_ layout: ZoneLayout) {
        let layouts = CustomLayoutStore.load(preferences).filter { $0.id != layout.id }
        CustomLayoutStore.save(layouts, preferences)
        rebuild()
    }
}

/// Tiny preview of a layout's zones (normalized rects drawn proportionally).
private final class LayoutThumbView: NSView {
    private let layout: ZoneLayout

    init(layout: ZoneLayout) {
        self.layout = layout
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        NSColor.quaternaryLabelColor.setFill()
        background.fill()

        for zone in layout.zones {
            let rect = CGRect(
                x: frame.minX + zone.x * frame.width,
                y: frame.minY + zone.y * frame.height,
                width: zone.w * frame.width,
                height: zone.h * frame.height
            ).insetBy(dx: 1.5, dy: 1.5)
            NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
