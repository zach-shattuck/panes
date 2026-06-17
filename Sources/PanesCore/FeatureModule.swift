import AppKit

/// A TCC permission Panes may require. Modules declare what they need;
/// ModuleRegistry refuses to start a module until everything it declared
/// is granted, so individual features never need permission-failure paths.
public nonisolated enum Permission: String, CaseIterable, Sendable {
    /// Accessibility (AXUIElement control, CGEventTaps on the session).
    case accessibility
    /// Screen Recording (ScreenCaptureKit window/display capture).
    case screenRecording
}

/// A per-module setting surfaced as a control in the Settings window and
/// persisted in PreferencesStore under `key`. Either a switch or a slider.
public nonisolated struct ModuleOption: Sendable {
    public enum Kind: Sendable, Equatable {
        case toggle
        case slider(min: Double, max: Double, step: Double, unit: String)
        /// A pick-one control rendered as a segmented control. The selected
        /// index is persisted as a Double in PreferencesStore.
        case choice(options: [String])
    }

    public let key: String
    public let title: String
    public let detail: String
    public let kind: Kind
    /// For a toggle, 0/1; for a slider, the numeric default.
    public let defaultValue: Double

    public static func toggle(key: String, title: String, detail: String, defaultOn: Bool) -> ModuleOption {
        ModuleOption(key: key, title: title, detail: detail, kind: .toggle, defaultValue: defaultOn ? 1 : 0)
    }

    public static func slider(
        key: String,
        title: String,
        detail: String,
        min: Double,
        max: Double,
        step: Double,
        unit: String,
        default defaultValue: Double
    ) -> ModuleOption {
        ModuleOption(
            key: key,
            title: title,
            detail: detail,
            kind: .slider(min: min, max: max, step: step, unit: unit),
            defaultValue: defaultValue
        )
    }

    public static func choice(
        key: String,
        title: String,
        detail: String,
        options: [String],
        defaultIndex: Int
    ) -> ModuleOption {
        ModuleOption(
            key: key,
            title: title,
            detail: detail,
            kind: .choice(options: options),
            defaultValue: Double(defaultIndex)
        )
    }

    private init(key: String, title: String, detail: String, kind: Kind, defaultValue: Double) {
        self.key = key
        self.title = title
        self.detail = detail
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// A rebindable global shortcut a module exposes. Declared in metadata (like
/// `ModuleOption`) so the Settings window can show and reset it even while the
/// module is disabled. The module binds a handler to `id` at start via
/// `ModuleContext.hotkeyBindings`; the user's override (if any) lives in
/// PreferencesStore and wins over `defaultSpec`.
public nonisolated struct HotkeyAction: Sendable {
    public let id: String
    /// Short label shown next to the recorder, e.g. "Snap to left half".
    public let title: String
    public let defaultSpec: HotkeyCenter.Spec

    public init(id: String, title: String, defaultSpec: HotkeyCenter.Spec) {
        self.id = id
        self.title = title
        self.defaultSpec = defaultSpec
    }
}

/// Static description of a feature module.
public nonisolated struct ModuleMetadata: Sendable {
    public let id: String
    public let displayName: String
    /// Group heading this feature is listed under in Settings (e.g. "Snapping",
    /// "Dock"). Related features share a category so they appear together.
    public let category: String
    public let summary: String
    /// Concrete instructions: the hotkey or gesture that drives the feature.
    /// Shown verbatim in the Settings window.
    public let howToUse: String
    public let requiredPermissions: Set<Permission>
    /// Optional per-module on/off settings.
    public let options: [ModuleOption]
    /// Rebindable global shortcuts this module exposes, shown under "Shortcuts".
    public let hotkeys: [HotkeyAction]
    /// Whether the module is on for users who have never touched the toggle.
    public let enabledByDefault: Bool

    public init(
        id: String,
        displayName: String,
        category: String = "Features",
        summary: String,
        howToUse: String,
        requiredPermissions: Set<Permission>,
        options: [ModuleOption] = [],
        hotkeys: [HotkeyAction] = [],
        enabledByDefault: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.summary = summary
        self.howToUse = howToUse
        self.requiredPermissions = requiredPermissions
        self.options = options
        self.hotkeys = hotkeys
        self.enabledByDefault = enabledByDefault
    }
}

/// Shared services handed to every module at start. Modules must route all
/// global event monitoring through `eventTaps` and all hotkeys through
/// `hotkeys` — never create their own CGEventTap or Carbon handler — so the
/// app maintains a single tap regardless of how many features are enabled.
@MainActor
public final class ModuleContext {
    public let permissions: PermissionsManager
    public let eventTaps: EventTapHub
    public let hotkeys: HotkeyCenter
    /// Resolves and live-updates each module's rebindable shortcuts. Modules
    /// should bind through this rather than calling `hotkeys` directly, so a
    /// shortcut changed in Settings re-registers without a restart.
    public let hotkeyBindings: HotkeyBindings
    public let preferences: PreferencesStore
    public let dock: DockModel

    /// Set true just before the app tears modules down at quit, so a module's
    /// `stop()` can tell a user-initiated disable (revert side effects) from
    /// app termination (leave the system as-is).
    public var isTerminating = false

    public init(
        permissions: PermissionsManager,
        eventTaps: EventTapHub,
        hotkeys: HotkeyCenter,
        preferences: PreferencesStore,
        dock: DockModel
    ) {
        self.permissions = permissions
        self.eventTaps = eventTaps
        self.hotkeys = hotkeys
        self.hotkeyBindings = HotkeyBindings(center: hotkeys, preferences: preferences)
        self.preferences = preferences
        self.dock = dock
    }
}

/// One toggleable feature. Lifecycle contract:
///  - `start(context:)` is called only when the module is enabled in
///    preferences AND all `requiredPermissions` are granted.
///  - `stop()` must release every subscription, hotkey, timer, and window the
///    module created. It is called on user disable, on permission revocation,
///    and at app termination. start/stop may be called repeatedly.
@MainActor
public protocol FeatureModule: AnyObject {
    var metadata: ModuleMetadata { get }
    func start(context: ModuleContext)
    func stop()
}
