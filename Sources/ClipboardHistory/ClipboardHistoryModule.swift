import AppKit
import Carbon.HIToolbox
import PanesCore

public final class ClipboardHistoryModule: FeatureModule {
    /// Preference key for the list of apps whose copies are never recorded
    /// (newline-joined bundle IDs).
    public static let excludedAppsKey = "clipboard.excludedBundleIDs"
    /// Preference key for the retention setting (index into `expiryDays`).
    public static let expiryKey = "clipboard.expiryChoice"
    /// Days for each retention choice; `0` means keep forever.
    public static let expiryDays: [Double] = [7, 30, 90, 0]
    private static let defaultExpiryIndex = 1

    /// The apps the user has excluded, decoded from preferences.
    public static func excludedBundleIDs(_ preferences: PreferencesStore) -> [String] {
        (preferences.string(forKey: excludedAppsKey) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    public static func setExcludedBundleIDs(_ ids: [String], _ preferences: PreferencesStore) {
        preferences.set(ids.joined(separator: "\n"), forKey: excludedAppsKey)
    }

    public let metadata = ModuleMetadata(
        id: "clipboard-history",
        displayName: "Clipboard History",
        category: "Clipboard & Screenshots",
        summary: "Keeps a searchable history of what you copy, including text, images, and files, so you can paste something from earlier.",
        howToUse: "Copy things the usual way with ⌘C. Use the shortcut below to open the history, type to search, use the up and down arrows to pick an item, and press Return to paste it where you were typing. Hover an item and click the pin to keep it at the top. Press Esc to close. Copies from password managers are skipped automatically.",
        // No hard requirements: capture and the panel work permissionless;
        // paste-back additionally lights up when Accessibility is granted.
        requiredPermissions: [],
        options: [
            .choice(
                key: expiryKey,
                title: "Keep history for",
                detail: "Older items are removed automatically. Pinned items are always kept.",
                options: ["1 week", "1 month", "3 months", "Forever"],
                defaultIndex: defaultExpiryIndex
            )
        ],
        hotkeys: [
            HotkeyAction(
                id: "clipboard-history.open",
                title: "Open clipboard history",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(kVK_ANSI_V),
                    carbonModifiers: UInt32(cmdKey | shiftKey)
                )
            ),
            HotkeyAction(
                id: "clipboard-history.pastePlain",
                title: "Paste as plain text",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(kVK_ANSI_V),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
                )
            ),
        ]
    )

    private var watcher: PasteboardWatcher?
    private var store: ClipboardStore?
    private var panel: HistoryPanel?
    private var openToken: HotkeyBindings.BindingToken?
    private var plainPasteToken: HotkeyBindings.BindingToken?
    private weak var bindings: HotkeyBindings?
    private weak var permissions: PermissionsManager?
    private weak var preferences: PreferencesStore?
    private var prefObserver: UUID?

    public init() {}

    public func start(context: ModuleContext) {
        permissions = context.permissions
        bindings = context.hotkeyBindings
        preferences = context.preferences
        let preferences = context.preferences

        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Panes", isDirectory: true)
        let store = ClipboardStore(directory: supportDirectory, maxAge: Self.maxAge(preferences))
        self.store = store

        let watcher = PasteboardWatcher(
            excludedBundleIDs: { Set(Self.excludedBundleIDs(preferences)) }
        ) { [weak self] kind, text, data, source in
            self?.store?.insert(kind: kind, text: text, data: data, sourceBundleID: source)
        }
        watcher.start()
        self.watcher = watcher

        let panel = HistoryPanel()
        panel.onQuery = { [weak self] query in
            self?.store?.recent(matching: query) ?? []
        }
        panel.onChoose = { [weak self] item in
            guard let self, let permissions = self.permissions else { return }
            PasteService.paste(item, permissions: permissions)
        }
        panel.onTogglePin = { [weak self] item in
            self?.store?.setPinned(item.id, !item.pinned)
        }
        self.panel = panel

        openToken = context.hotkeyBindings.bind("clipboard-history.open") { [weak self] in
            self?.panel?.toggle()
        }
        plainPasteToken = context.hotkeyBindings.bind("clipboard-history.pastePlain") { [weak self] in
            guard let self, let permissions = self.permissions else { return }
            PasteService.pasteCurrentAsPlainText(permissions: permissions)
        }

        // React to the retention setting changing: re-apply and prune now so a
        // shorter window takes effect immediately.
        prefObserver = preferences.observe { [weak self] key in
            guard key == Self.expiryKey, let self else { return }
            self.store?.maxAge = Self.maxAge(preferences)
            self.store?.pruneNow()
        }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        bindings?.unbind(openToken)
        bindings?.unbind(plainPasteToken)
        openToken = nil
        plainPasteToken = nil
        if let prefObserver { preferences?.removeObserver(prefObserver) }
        prefObserver = nil
        panel?.hide()
        panel = nil
        store = nil
    }

    /// Resolve the retention setting to a max age in seconds (0 = forever).
    private static func maxAge(_ preferences: PreferencesStore) -> TimeInterval {
        let index = Int(preferences.double(forKey: expiryKey, default: Double(defaultExpiryIndex)).rounded())
        let days = expiryDays.indices.contains(index) ? expiryDays[index] : expiryDays[defaultExpiryIndex]
        return days <= 0 ? 0 : days * 24 * 60 * 60
    }
}
