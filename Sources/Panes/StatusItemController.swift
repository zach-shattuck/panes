import AppKit
import PanesCore
import ServiceManagement

/// The menu bar item: per-module toggles, permission status/actions, launch
/// at login, quit. The menu is rebuilt lazily on open via NSMenuDelegate so
/// toggle and permission state are always current without any observation
/// plumbing.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let registry: ModuleRegistry
    private let statusItem: NSStatusItem
    private let onOpenSettings: () -> Void
    var chrome: AppChrome?

    func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    init(registry: ModuleRegistry, onOpenSettings: @escaping () -> Void) {
        self.registry = registry
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = Self.menuBarImage()
            image?.size = NSSize(width: 18, height: 18)
            // Monochrome template: macOS tints it to match the menu bar
            // (dark in light mode, light in dark mode) — the native look.
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        var lastCategory: String?
        for module in registry.modules {
            // Visually separate the feature groups (Snapping, Dock, etc.).
            if let last = lastCategory, last != module.metadata.category {
                menu.addItem(.separator())
            }
            lastCategory = module.metadata.category

            let item = NSMenuItem(
                title: module.metadata.displayName,
                action: #selector(toggleModule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = module.metadata.id
            item.state = registry.isEnabled(module) ? .on : .off
            let missing = registry.missingPermissions(for: module)
            if registry.isEnabled(module), !missing.isEmpty {
                let names = missing.map { $0 == .accessibility ? "Accessibility" : "Screen Recording" }
                    .joined(separator: " and ")
                item.toolTip = "Needs \(names) to work."
                item.badge = NSMenuItemBadge(string: "needs permission")
            } else {
                item.toolTip = module.metadata.summary
            }
            menu.addItem(item)
        }

        let missing = registry.missingPermissionsForEnabledModules()
        if !missing.isEmpty {
            menu.addItem(.separator())
            for permission in missing.sorted(by: { $0.rawValue < $1.rawValue }) {
                let title: String
                switch permission {
                case .accessibility: title = "Grant Accessibility Access…"
                case .screenRecording: title = "Grant Screen Recording Access…"
                }
                let item = NSMenuItem(
                    title: title,
                    action: #selector(grantPermission(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = permission.rawValue
                menu.addItem(item)
            }
        }
        if registry.context.permissions.screenRecordingNeedsRelaunch {
            let item = NSMenuItem(
                title: "Relaunch Panes to Finish Setup…",
                action: #selector(relaunch),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        if let chrome {
            let dockItem = NSMenuItem(title: "Hide from Dock", action: #selector(toggleHideFromDock), keyEquivalent: "")
            dockItem.target = self
            dockItem.state = chrome.hiddenFromDock ? .on : .off
            menu.addItem(dockItem)

            let menuBarItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleHideFromMenuBar), keyEquivalent: "")
            menuBarItem.target = self
            menuBarItem.state = chrome.hiddenFromMenuBar ? .on : .off
            menuBarItem.toolTip = "Reopen Settings any time by searching for Panes in Spotlight or your launcher."
            menu.addItem(menuBarItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Panes", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Loads the Panes logo mark for the menu bar. Tries the asset-style
    /// lookup, then an explicit bundle path (loose resources don't always
    /// resolve via NSImage(named:)), then an SF Symbol as a last resort.
    private static func menuBarImage() -> NSImage? {
        if let named = NSImage(named: "MenuBarIcon") { return named }
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Panes")
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func toggleHideFromDock() {
        guard let chrome else { return }
        chrome.setHiddenFromDock(!chrome.hiddenFromDock)
    }

    @objc private func toggleHideFromMenuBar() {
        guard let chrome else { return }
        chrome.setHiddenFromMenuBar(!chrome.hiddenFromMenuBar)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard
            let id = sender.representedObject as? String,
            let module = registry.modules.first(where: { $0.metadata.id == id })
        else { return }
        registry.setEnabled(module, !registry.isEnabled(module))
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let permission = Permission(rawValue: raw)
        else { return }
        registry.context.permissions.request(permission)
    }

    @objc private func relaunch() {
        registry.context.permissions.relaunchApp()
    }

    @objc private func toggleLaunchAtLogin() {
        // SMAppService only works from a real .app bundle; from the bare
        // SwiftPM dev executable this throws and is logged, not fatal.
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at login toggle failed: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
