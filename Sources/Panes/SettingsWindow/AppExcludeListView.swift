import AppKit
import ClipboardHistory
import PanesCore
import UniformTypeIdentifiers

/// Editor for the clipboard "don't record from these apps" list: a row per
/// excluded app (icon, name, remove) plus an "Add App…" button that picks an
/// app and stores its bundle id. Reads/writes through `ClipboardHistoryModule`
/// so the watcher and this view share one source of truth.
final class AppExcludeListView: NSStackView {
    private let preferences: PreferencesStore

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

        let ids = ClipboardHistoryModule.excludedBundleIDs(preferences)
        if ids.isEmpty {
            let none = NSTextField(labelWithString: "No apps excluded.")
            none.font = .systemFont(ofSize: 11.5)
            none.textColor = .tertiaryLabelColor
            addArrangedSubview(none)
        } else {
            for id in ids {
                let row = appRow(for: id)
                addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }

        let add = ClosureButton(title: "Add App…") { [weak self] in self?.addApp() }
        addArrangedSubview(add)
    }

    private func appRow(for bundleID: String) -> NSView {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)

        let icon = NSImageView()
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let remove = ClosureButton(title: "Remove") { [weak self] in self?.remove(bundleID) }

        let row = NSStackView(views: [icon, label, spacer, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app whose copies should not be saved to history."
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }

        var ids = ClipboardHistoryModule.excludedBundleIDs(preferences)
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        ClipboardHistoryModule.setExcludedBundleIDs(ids, preferences)
        rebuild()
    }

    private func remove(_ bundleID: String) {
        let ids = ClipboardHistoryModule.excludedBundleIDs(preferences).filter { $0 != bundleID }
        ClipboardHistoryModule.setExcludedBundleIDs(ids, preferences)
        rebuild()
    }
}
