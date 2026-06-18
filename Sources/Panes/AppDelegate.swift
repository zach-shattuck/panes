import AppKit
import PanesCore
import WindowSnapping
import KeyboardSnapping
import DockPreviews
import DockComfort
import ClipboardHistory
import ScreenshotTool
import FinderCutPaste
import AeroShake
import AltTabSwitcher
import WindowToDisplay

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: ModuleContext!
    private var registry: ModuleRegistry!
    private var statusItem: StatusItemController!
    private var settings: SettingsWindowController!
    private var chrome: AppChrome!
    private var welcome: WelcomeWindowController!

    private static let hasLaunchedKey = "app.hasLaunchedBefore"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = ModuleContext(
            permissions: PermissionsManager(),
            eventTaps: EventTapHub(),
            hotkeys: HotkeyCenter(),
            preferences: PreferencesStore(),
            dock: DockModel()
        )
        self.context = context

        let registry = ModuleRegistry(context: context)
        registry.register(WindowSnappingModule())
        registry.register(KeyboardSnappingModule())
        registry.register(DockPreviewsModule())
        registry.register(DockClickModule())
        registry.register(MinimizeIntoIconModule())
        registry.register(ClipboardHistoryModule())
        registry.register(ScreenshotModule())
        registry.register(FinderCutPasteModule())
        registry.register(AeroShakeModule())
        registry.register(AltTabSwitcherModule())
        registry.register(WindowToDisplayModule())
        self.registry = registry

        let statusItem = StatusItemController(registry: registry) { [weak self] in
            self?.settings.show()
        }
        self.statusItem = statusItem

        let chrome = AppChrome(
            preferences: context.preferences,
            applyStatusItemVisible: { [weak statusItem] visible in statusItem?.setStatusItemVisible(visible) }
        )
        self.chrome = chrome
        statusItem.chrome = chrome

        settings = SettingsWindowController(registry: registry, chrome: chrome)

        chrome.apply()
        registry.syncRunningState()

        // First launch: show the welcome note, then "Get Started" opens the
        // guide so features and permissions are discoverable. Returning users
        // get a quiet re-request to reconnect any module whose permission was
        // revoked.
        if !context.preferences.bool(forKey: Self.hasLaunchedKey, default: false) {
            context.preferences.set(true, forKey: Self.hasLaunchedKey)
            let welcome = WelcomeWindowController { [weak self] in self?.settings.show() }
            self.welcome = welcome
            welcome.show()
        } else if let permission = registry.missingPermissionsForEnabledModules()
            .sorted(by: { $0.rawValue < $1.rawValue }).first {
            context.permissions.request(permission)
        }
    }

    /// Fired when the user "launches" Panes while it's already running —
    /// from Raycast/Spotlight/Launchpad/Finder. A menu-bar app has no window
    /// to bring forward, so open the Settings & Guide window instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Tell modules this is a quit, not a user-disable, so e.g. the
        // minimize-into-icon module doesn't revert the Dock on every quit.
        context.isTerminating = true
        registry.stopAll()
    }
}
