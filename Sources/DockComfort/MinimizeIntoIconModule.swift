import AppKit
import PanesCore
import os

/// Makes minimized windows collapse INTO the app's Dock icon instead of
/// piling up as separate minimized tiles on the side of the Dock — so the
/// Dock stays tidy and you still see an app is open via the running dot.
///
/// This drives macOS's own built-in "Minimize windows into application icon"
/// setting (`com.apple.dock minimize-to-application`) and restarts the Dock
/// to apply it — there is no per-window API to hide individual minimized
/// tiles, so the native setting is the clean mechanism.
public final class MinimizeIntoIconModule: FeatureModule {
    public let metadata = ModuleMetadata(
        id: "minimize-into-icon",
        displayName: "Minimize Into App Icon",
        category: "Dock",
        summary: "Minimized windows tuck into the app's Dock icon instead of piling up as separate tiles. You can still tell the app is open by the dot under its icon.",
        howToUse: "Turn this on, then minimize windows the usual way (the yellow button or Cmd+M) and they fold into the app's icon instead of stacking up on the Dock. Turn it off to go back to separate tiles. Switching this briefly restarts the Dock.",
        requiredPermissions: [],
        enabledByDefault: false
    )

    private static let dockDomain = "com.apple.dock"
    private static let key = "minimize-to-application"
    private weak var context: ModuleContext?
    private let log = Logger.panes("dock-minimize")

    public init() {}

    public func start(context: ModuleContext) {
        self.context = context
        apply(true)
    }

    public func stop() {
        // On a user-initiated disable, restore separate tiles. On app quit,
        // leave the Dock as the user has it — don't restart the Dock on every
        // quit (context.isTerminating distinguishes the two).
        if context?.isTerminating == true { return }
        apply(false)
    }

    private func apply(_ minimizeToApp: Bool) {
        guard readCurrent() != minimizeToApp else { return } // already in the desired state
        write(minimizeToApp)
        restartDock()
        log.info("set minimize-to-application=\(minimizeToApp)")
    }

    private func readCurrent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", Self.dockDomain, Self.key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false } // key unset
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "1"
    }

    private func write(_ value: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", Self.dockDomain, Self.key, "-bool", value ? "true" : "false"]
        try? process.run()
        process.waitUntilExit()
    }

    private func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
