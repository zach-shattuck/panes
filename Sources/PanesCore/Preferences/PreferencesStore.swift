import Foundation

/// UserDefaults-backed preferences with change observation.
///
/// Key layout: module enablement under "module.<id>.enabled"; module-specific
/// settings are namespaced by the module itself ("screenshot.freezeFrame").
@MainActor
public final class PreferencesStore {
    private let defaults: UserDefaults
    private var observers: [UUID: (String) -> Void] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Module enablement

    public func isModuleEnabled(_ metadata: ModuleMetadata) -> Bool {
        let key = Self.enabledKey(metadata.id)
        if defaults.object(forKey: key) == nil {
            return metadata.enabledByDefault
        }
        return defaults.bool(forKey: key)
    }

    public func setModule(_ id: String, enabled: Bool) {
        set(enabled, forKey: Self.enabledKey(id))
    }

    private static func enabledKey(_ id: String) -> String {
        "module.\(id).enabled"
    }

    // MARK: Typed access

    public func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    public func integer(forKey key: String, default defaultValue: Int) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }

    public func double(forKey key: String, default defaultValue: Double) -> Double {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
        for observer in observers.values { observer(key) }
    }

    /// Removes a stored value so reads fall back to their default. Notifies
    /// observers like `set` does (used to reset a customized shortcut).
    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
        for observer in observers.values { observer(key) }
    }

    // MARK: Observation

    @discardableResult
    public func observe(_ handler: @escaping (_ changedKey: String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
