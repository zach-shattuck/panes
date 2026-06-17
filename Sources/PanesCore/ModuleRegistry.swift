import AppKit
import os

/// Owns all feature modules and reconciles their running state against two
/// inputs: the user's enable/disable toggles and live TCC permission state.
/// A module runs iff (enabled && all required permissions granted); anything
/// else is stopped. Reconciliation is idempotent and runs on every
/// preference or permission change.
@MainActor
public final class ModuleRegistry {
    public let context: ModuleContext
    public private(set) var modules: [FeatureModule] = []
    private var running: Set<String> = []
    private let log = Logger.panes("registry")

    public init(context: ModuleContext) {
        self.context = context
        context.permissions.observe { [weak self] _ in
            self?.context.eventTaps.refresh()
            self?.syncRunningState()
        }
        context.preferences.observe { [weak self] key in
            guard key.hasPrefix("module.") else { return }
            self?.syncRunningState()
        }
    }

    public func register(_ module: FeatureModule) {
        modules.append(module)
        // Make the module's shortcuts resolvable/editable even before (or
        // without) the module ever starting.
        context.hotkeyBindings.registerCatalog(module.metadata.hotkeys)
    }

    public func isRunning(_ id: String) -> Bool {
        running.contains(id)
    }

    public func isEnabled(_ module: FeatureModule) -> Bool {
        context.preferences.isModuleEnabled(module.metadata)
    }

    public func setEnabled(_ module: FeatureModule, _ enabled: Bool) {
        context.preferences.setModule(module.metadata.id, enabled: enabled)
        if enabled {
            // Kick off permission prompts for whatever this module needs.
            for permission in missingPermissions(for: module) {
                context.permissions.request(permission)
            }
        }
        syncRunningState()
    }

    public func missingPermissions(for module: FeatureModule) -> Set<Permission> {
        module.metadata.requiredPermissions.subtracting(context.permissions.granted)
    }

    /// All permissions needed by enabled-but-not-yet-runnable modules —
    /// drives onboarding.
    public func missingPermissionsForEnabledModules() -> Set<Permission> {
        modules
            .filter { isEnabled($0) }
            .reduce(into: Set<Permission>()) { $0.formUnion(missingPermissions(for: $1)) }
    }

    public func syncRunningState() {
        for module in modules {
            let id = module.metadata.id
            let shouldRun = isEnabled(module) && missingPermissions(for: module).isEmpty
            switch (shouldRun, running.contains(id)) {
            case (true, false):
                log.info("starting module \(id, privacy: .public)")
                module.start(context: context)
                running.insert(id)
            case (false, true):
                log.info("stopping module \(id, privacy: .public)")
                module.stop()
                running.remove(id)
            default:
                break
            }
        }
    }

    public func stopAll() {
        for module in modules where running.contains(module.metadata.id) {
            module.stop()
        }
        running.removeAll()
    }
}
