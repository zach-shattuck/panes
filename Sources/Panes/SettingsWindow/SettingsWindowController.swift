import AppKit
import PanesCore
import DockPreviews
import ClipboardHistory
import WindowSnapping

/// Settings & Guide window — a sidebar of every feature plus a "General"
/// entry; selecting one shows its controls and how-to in the detail pane.
/// Doubles as the app's documentation so every feature is discoverable.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private enum Item {
        case general
        case module(FeatureModule)
    }

    private let registry: ModuleRegistry
    private let chrome: AppChrome
    private var window: NSWindow?
    private let sidebarStack = FlippedStack()
    private let detailStack = FlippedStack()
    private var rows: [SidebarRow] = []
    private var items: [Item] = []
    private var selected = 0

    private static let textWidth: CGFloat = 420
    private static let cardInset: CGFloat = 0

    /// Where the "Support Panes" button goes (the PayPal business profile).
    private static let supportURL = "https://www.paypal.biz/zachsoftworks"

    init(registry: ModuleRegistry, chrome: AppChrome) {
        self.registry = registry
        self.chrome = chrome
        super.init()
        registry.context.permissions.observe { [weak self] _ in
            self?.reloadSidebar()
            self?.renderDetail()
        }
    }

    func show() {
        if window == nil { makeWindow() }
        // Stay .accessory so Panes never appears in the Dock; an accessory
        // app can still raise a key window.
        NSApp.activate(ignoringOtherApps: true)
        reloadSidebar()
        renderDetail()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Window

    private func makeWindow() {
        items = [.general] + registry.modules.map(Item.module)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Panes Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 420)
        window.center()

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar.
        let sidebarScroll = NSScrollView()
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarStack
        let sidebarBG = NSVisualEffectView()
        sidebarBG.material = .sidebar
        sidebarBG.state = .active
        sidebarBG.translatesAutoresizingMaskIntoConstraints = false
        sidebarBG.addSubview(sidebarScroll)
        pin(sidebarScroll, to: sidebarBG)
        NSLayoutConstraint.activate([sidebarStack.widthAnchor.constraint(equalTo: sidebarScroll.widthAnchor)])

        // Detail.
        let detailScroll = NSScrollView()
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 12
        detailStack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 26, right: 26)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailStack
        NSLayoutConstraint.activate([detailStack.widthAnchor.constraint(equalTo: detailScroll.widthAnchor)])

        split.addArrangedSubview(sidebarBG)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        // Wrap in a plain container as the contentView, then pin the split
        // to it. (Pinning the split to itself — which happens if you make it
        // the contentView directly while AutoLayout is on — gives it zero
        // size and a blank window.)
        let container = NSView()
        window.contentView = container
        container.addSubview(split)
        pin(split, to: container)
        sidebarBG.widthAnchor.constraint(equalToConstant: 200).isActive = true
        self.window = window
    }

    // MARK: Sidebar

    private func reloadSidebar() {
        guard window != nil else { return }
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        var lastCategory: String?
        for (index, item) in items.enumerated() {
            // Insert a group heading before the first feature of each category.
            if case .module(let module) = item {
                let category = module.metadata.category
                if category != lastCategory {
                    let header = categoryHeader(category)
                    sidebarStack.addArrangedSubview(header)
                    header.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -20).isActive = true
                    lastCategory = category
                }
            }
            let row = SidebarRow(title: title(for: item), status: status(for: item), selected: index == selected) { [weak self] in
                self?.select(index)
            }
            sidebarStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -20).isActive = true
            rows.append(row)
        }
    }

    private func categoryHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    private func select(_ index: Int) {
        selected = index
        for (i, row) in rows.enumerated() { row.setSelected(i == index) }
        renderDetail()
    }

    private func title(for item: Item) -> String {
        switch item {
        case .general: return "General"
        case .module(let module): return module.metadata.displayName
        }
    }

    private func status(for item: Item) -> SidebarRow.Status {
        switch item {
        case .general:
            return registry.missingPermissionsForEnabledModules().isEmpty ? .none : .warning
        case .module(let module):
            if !registry.isEnabled(module) { return .off }
            return registry.missingPermissions(for: module).isEmpty ? .on : .warning
        }
    }

    // MARK: Detail

    private func renderDetail() {
        guard window != nil, items.indices.contains(selected) else { return }
        detailStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch items[selected] {
        case .general: renderGeneral()
        case .module(let module): renderModule(module)
        }
    }

    private func renderGeneral() {
        addDetail(bigTitle("Panes"))
        addDetail(wrappingLabel(
            "Handy desktop comfort features for your Mac. Pick a feature on the left to turn it on and see how it works. Each one runs on its own, so just turn on the ones you want.",
            size: 13, color: .secondaryLabelColor
        ))
        addDetail(spacer(8))
        addDetail(sectionLabel("Permissions"))
        for permission in Permission.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            addDetail(permissionRow(permission))
        }
        if registry.context.permissions.screenRecordingNeedsRelaunch {
            addDetail(ClosureButton(title: "Relaunch Panes to finish setup") { [weak self] in
                self?.registry.context.permissions.relaunchApp()
            })
        }
        addDetail(spacer(8))
        addDetail(wrappingLabel(
            "Features that need a permission will say so until you grant it. Grant it once here and those features start working on their own.",
            size: 11.5, color: .tertiaryLabelColor
        ))

        addDetail(spacer(12))
        addDetail(sectionLabel("Appearance"))
        addDetail(appToggleRow(
            title: "Hide from Dock",
            detail: "Keep Panes out of the Dock. Turn this off to show a Dock icon.",
            isOn: chrome.hiddenFromDock
        ) { [weak self] on in self?.chrome.setHiddenFromDock(on) })
        addDetail(appToggleRow(
            title: "Hide menu bar icon",
            detail: "Remove the Panes icon from the menu bar. You can still reopen this window any time by searching for Panes in Spotlight or your launcher.",
            isOn: chrome.hiddenFromMenuBar
        ) { [weak self] on in self?.chrome.setHiddenFromMenuBar(on) })

        addDetail(spacer(12))
        addDetail(sectionLabel("Support"))
        addDetail(wrappingLabel(
            "Panes is free and nothing is locked behind a paywall. If it earns a spot on your Mac, you can chip in. No pressure.",
            size: 11.5, color: .secondaryLabelColor
        ))
        addDetail(ClosureButton(title: "Support Panes") {
            if let url = URL(string: Self.supportURL) { NSWorkspace.shared.open(url) }
        })
    }

    /// A toggle row for an app-level setting (not tied to a feature module).
    private func appToggleRow(title: String, detail: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        let toggle = ClosureSwitch(isOn: isOn) { on in onChange(on) }
        toggle.controlSize = .small
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        col.addArrangedSubview(titleLabel)
        col.addArrangedSubview(wrappingLabel(detail, size: 11.5, color: .secondaryLabelColor))
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(col)
        return row
    }

    private func renderModule(_ module: FeatureModule) {
        let meta = module.metadata
        let enabled = registry.isEnabled(module)

        // Title row + master switch.
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        let title = bigTitle(meta.displayName)
        let spacerView = NSView()
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toggle = ClosureSwitch(isOn: enabled) { [weak self] on in
            guard let self else { return }
            self.registry.setEnabled(module, on)
            self.reloadSidebar()
            self.renderDetail()
        }
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(spacerView)
        titleRow.addArrangedSubview(toggle)
        addDetail(titleRow)

        addDetail(wrappingLabel(meta.summary, size: 13, color: .labelColor))

        let missing = registry.missingPermissions(for: module)
        if enabled, !missing.isEmpty {
            let names = missing.map { $0 == .accessibility ? "Accessibility" : "Screen Recording" }.joined(separator: " and ")
            let warn = NSStackView()
            warn.orientation = .horizontal
            warn.spacing = 8
            warn.alignment = .centerY
            warn.addArrangedSubview(wrappingLabel("This feature needs \(names) to work.", size: 12, color: .systemOrange))
            for permission in missing.sorted(by: { $0.rawValue < $1.rawValue }) {
                warn.addArrangedSubview(ClosureButton(title: "Grant…") { [weak self] in
                    self?.registry.context.permissions.request(permission)
                })
            }
            addDetail(warn)
        }

        addDetail(spacer(6))
        addDetail(sectionLabel("How to use"))
        addDetail(wrappingLabel(meta.howToUse, size: 12.5, color: .secondaryLabelColor))

        if !meta.hotkeys.isEmpty {
            addDetail(spacer(8))
            addDetail(sectionLabel("Shortcuts"))
            for action in meta.hotkeys {
                addDetail(HotkeyRecorderControl(action: action, bindings: registry.context.hotkeyBindings))
            }
            addDetail(wrappingLabel(
                "Click a shortcut to record a new one. Use the reset arrow to restore the default.",
                size: 11.5, color: .tertiaryLabelColor
            ))
        }

        if !meta.options.isEmpty {
            addDetail(spacer(8))

            // A live miniature that reflects the visual options as they change.
            let sample = meta.id == "dock-previews" ? DockPreviewSampleView() : nil
            let refresh: (() -> Void)? = sample.map { view in
                { [weak self] in self?.updateDockSample(view) }
            }
            if let sample {
                addDetail(sectionLabel("Preview"))
                addDetail(sample)
                sample.heightAnchor.constraint(equalToConstant: 224).isActive = true
                updateDockSample(sample)
            }

            addDetail(sectionLabel("Options"))
            for option in meta.options {
                addDetail(makeOptionRow(option, onChange: refresh))
            }
        }

        if meta.id == "clipboard-history" {
            addDetail(spacer(8))
            addDetail(sectionLabel("Excluded apps"))
            addDetail(wrappingLabel(
                "Copies you make while one of these apps is in front are never saved to history.",
                size: 11.5, color: .secondaryLabelColor
            ))
            addDetail(AppExcludeListView(preferences: registry.context.preferences))
        }

        if meta.id == "window-snapping" {
            addDetail(spacer(8))
            addDetail(sectionLabel("Custom layouts"))
            addDetail(wrappingLabel(
                "Design your own zone layouts. They show up in the layout palette when you drag a window to the top of the screen.",
                size: 11.5, color: .secondaryLabelColor
            ))
            addDetail(CustomLayoutsView(preferences: registry.context.preferences))
        }
    }

    private func updateDockSample(_ view: DockPreviewSampleView) {
        let prefs = registry.context.preferences
        let scale = prefs.double(forKey: DockPreviewsModule.previewSizeKey, default: 100) / 100
        let frosted = Int(prefs.double(forKey: DockPreviewsModule.backingStyleKey, default: 0).rounded()) == 0
        let monochrome = prefs.bool(forKey: DockPreviewsModule.monochromeKey, default: false)
        view.update(scale: scale, frosted: frosted, monochrome: monochrome)
    }

    // MARK: Detail builders

    private func addDetail(_ view: NSView) {
        detailStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -52).isActive = true
    }

    private func permissionRow(_ permission: Permission) -> NSView {
        let granted = registry.context.permissions.isGranted(permission)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        let dot = NSTextField(labelWithString: granted ? "✓" : "•")
        dot.textColor = granted ? .systemGreen : .systemOrange
        dot.font = .systemFont(ofSize: 13, weight: .bold)
        row.addArrangedSubview(dot)
        let name = permission == .accessibility ? "Accessibility" : "Screen Recording"
        let label = NSTextField(labelWithString: granted ? "\(name): granted" : "\(name): needed by some features")
        label.font = .systemFont(ofSize: 12)
        row.addArrangedSubview(label)
        if !granted {
            row.addArrangedSubview(ClosureButton(title: "Grant…") { [weak self] in
                self?.registry.context.permissions.request(permission)
            })
        }
        return row
    }

    private func makeOptionRow(_ option: ModuleOption, onChange: (() -> Void)?) -> NSView {
        switch option.kind {
        case .toggle: return makeToggleRow(option, onChange: onChange)
        case .slider(let min, let max, let step, let unit):
            return makeSliderRow(option, min: min, max: max, step: step, unit: unit, onChange: onChange)
        case .choice(let options):
            return makeChoiceRow(option, options: options, onChange: onChange)
        }
    }

    private func makeChoiceRow(_ option: ModuleOption, options: [String], onChange: (() -> Void)?) -> NSView {
        let selected = Int(registry.context.preferences.double(forKey: option.key, default: option.defaultValue).rounded())
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        let title = NSTextField(labelWithString: option.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        col.addArrangedSubview(title)
        let segmented = ClosureSegmented(labels: options, selected: selected) { [weak self] index in
            self?.registry.context.preferences.set(Double(index), forKey: option.key)
            onChange?()
        }
        col.addArrangedSubview(segmented)
        col.addArrangedSubview(wrappingLabel(option.detail, size: 11.5, color: .secondaryLabelColor))
        return col
    }

    private func makeToggleRow(_ option: ModuleOption, onChange: (() -> Void)?) -> NSView {
        let isOn = registry.context.preferences.bool(forKey: option.key, default: option.defaultValue != 0)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        let toggle = ClosureSwitch(isOn: isOn) { [weak self] on in
            self?.registry.context.preferences.set(on, forKey: option.key)
            onChange?()
        }
        toggle.controlSize = .small
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        let title = NSTextField(labelWithString: option.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        col.addArrangedSubview(title)
        col.addArrangedSubview(wrappingLabel(option.detail, size: 11.5, color: .secondaryLabelColor))
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(col)
        return row
    }

    private func makeSliderRow(_ option: ModuleOption, min: Double, max: Double, step: Double, unit: String, onChange: (() -> Void)?) -> NSView {
        let value = registry.context.preferences.double(forKey: option.key, default: option.defaultValue)
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        let title = NSTextField(labelWithString: option.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        col.addArrangedSubview(title)

        let valueLabel = NSTextField(labelWithString: Self.format(value, unit: unit, step: step))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        let slider = ClosureSlider(value: value, min: min, max: max) { [weak self] raw in
            let snapped = (raw / step).rounded() * step
            self?.registry.context.preferences.set(snapped, forKey: option.key)
            valueLabel.stringValue = Self.format(snapped, unit: unit, step: step)
            onChange?()
        }
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 10
        sliderRow.alignment = .centerY
        sliderRow.addArrangedSubview(slider)
        sliderRow.addArrangedSubview(valueLabel)
        col.addArrangedSubview(sliderRow)
        col.addArrangedSubview(wrappingLabel(option.detail, size: 11.5, color: .secondaryLabelColor))
        return col
    }

    private func bigTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        return label
    }

    private func sectionLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = Self.textWidth
        return label
    }

    private func pin(_ view: NSView, to container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    private static func format(_ value: Double, unit: String, step: Double) -> String {
        // Whole-number steps read better without decimals (e.g. "7", "100 %").
        let number = String(format: step < 1 ? "%.2f" : "%.0f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

/// A clickable sidebar row with a status dot.
private final class SidebarRow: NSView {
    enum Status { case on, off, warning, none }

    private let onClick: () -> Void
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let background = NSView()

    init(title: String, status: Status, selected: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)

        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        label.stringValue = title
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(dot)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -6),
        ])

        setStatus(status)
        setSelected(selected)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setSelected(_ selected: Bool) {
        background.layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        label.textColor = selected ? .controlAccentColor : .labelColor
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }

    private func setStatus(_ status: Status) {
        switch status {
        case .on: dot.layer?.backgroundColor = NSColor.systemGreen.cgColor; dot.isHidden = false
        case .warning: dot.layer?.backgroundColor = NSColor.systemOrange.cgColor; dot.isHidden = false
        case .off: dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor; dot.isHidden = false
        case .none: dot.isHidden = true
        }
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}
