import Foundation

/// Reads and toggles the Dock's auto-hide via the long-stable CoreDock SPI,
/// resolved at runtime so a missing symbol degrades to a harmless no-op. Used
/// to keep an auto-hide Dock revealed while a preview is on screen.
@MainActor
enum DockAutohide {
    private typealias GetEnabled = @convention(c) () -> Bool
    private typealias SetEnabled = @convention(c) (Bool) -> Void

    private static let getFn: GetEnabled? = symbol("CoreDockGetAutoHideEnabled").map {
        unsafeBitCast($0, to: GetEnabled.self)
    }
    private static let setFn: SetEnabled? = symbol("CoreDockSetAutoHideEnabled").map {
        unsafeBitCast($0, to: SetEnabled.self)
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
    }

    /// Whether the Dock is set to auto-hide. `nil` if the SPI isn't available.
    static var isEnabled: Bool? { getFn?() }

    static func setEnabled(_ enabled: Bool) { setFn?(enabled) }
}
