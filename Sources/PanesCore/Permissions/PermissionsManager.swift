import AppKit
import ApplicationServices
import ScreenCaptureKit
import os

/// Central TCC permission state.
///
/// macOS gives no callback when the user flips a switch in System Settings,
/// so this manager (a) re-checks on every app activation, (b) listens to the
/// undocumented-but-stable "com.apple.accessibility.api" distributed
/// notification (fires on ANY app's accessibility change, no payload — used
/// as a re-check hint), and (c) polls at 1 Hz
/// while a request is outstanding. Observers fire only on actual changes.
///
/// Gotchas this class is built around (verified empirically against macOS):
///  - Accessibility: `AXIsProcessTrustedWithOptions` shows the system prompt
///    at most once; afterwards the user must be sent to System Settings.
///    `AXIsProcessTrusted()` IS live — a grant takes effect immediately for
///    new AX calls, and event taps created after the grant work. No relaunch.
///  - Screen Recording: `CGPreflightScreenCaptureAccess()` and
///    `CGRequestScreenCaptureAccess()` return values are CACHED FOR THE
///    PROCESS LIFETIME — they must never be polled for live detection.
///    The live probe is attempting `SCShareableContent` enumeration
///    (succeeds iff granted, works mid-process), wrapped in a timeout
///    because replayd can hang. SCK starts working right after a grant, but
///    legacy CG paths only honor it after relaunch — hence
///    `screenRecordingNeedsRelaunch` for belt-and-braces onboarding.
///  - TCC binds grants to bundle ID + code-signing designated requirement;
///    ad-hoc/unsigned dev builds collapse to a per-build cdhash, so every
///    rebuild is a new TCC identity that shows as granted-but-untrusted.
///    Sign dev builds with a stable certificate; recover with
///    `tccutil reset Accessibility <bundle-id>`.
@MainActor
public final class PermissionsManager {
    public private(set) var granted: Set<Permission> = []

    /// True when Screen Recording was granted during this process's
    /// lifetime: SCK already works, but legacy CG capture paths won't until
    /// relaunch — the UI should offer a "Relaunch Panes" button.
    public private(set) var screenRecordingNeedsRelaunch = false

    private var observers: [UUID: (Set<Permission>) -> Void] = [:]
    private var pollTimer: Timer?
    private var pollDeadline: Date?
    /// Live screen-recording state. Seeded from the (launch-time-accurate)
    /// preflight, updated only by the SCShareableContent probe.
    private var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    /// Probe only after we showed (or sent the user to) the prompt — an
    /// unauthorized SCShareableContent call itself triggers the system
    /// prompt, which must never happen as a side effect of idle polling.
    private var screenRecordingRequested = false
    private var probeInFlight = false
    private let log = Logger.panes("permissions")

    public init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PermissionsHolder.shared?.appActivated() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PermissionsHolder.shared?.refresh() }
        }
        PermissionsHolder.shared = self
    }

    // MARK: Status

    public func isGranted(_ permission: Permission) -> Bool {
        granted.contains(permission)
    }

    public func isGranted(_ permissions: Set<Permission>) -> Bool {
        permissions.isSubset(of: granted)
    }

    /// On app activation, re-check live permissions — including a Screen
    /// Recording REVOCATION, which is otherwise undetectable (preflight is
    /// cached for the process lifetime and our grant flag only latched up).
    private func appActivated() {
        probeScreenRecordingIfNeeded()
        refresh()
    }

    public func refresh() {
        var now: Set<Permission> = []
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if screenRecordingGranted { now.insert(.screenRecording) }
        guard now != granted else { return }
        granted = now
        log.info("permissions changed: \(now.map(\.rawValue).joined(separator: ","), privacy: .public)")
        for observer in observers.values { observer(now) }
        if pollTimer != nil, Permission.allCases.allSatisfy({ now.contains($0) }) {
            stopPolling()
        }
    }

    // MARK: Requests

    /// Triggers the system prompt if it has never been shown, otherwise deep
    /// links into the right System Settings pane. Begins polling for a grant.
    public func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            if !AXIsProcessTrusted() {
                // Literal spelling of kAXTrustedCheckOptionPrompt — the SDK
                // global is a C `var` and not concurrency-safe in Swift 6.
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
            }
        case .screenRecording:
            screenRecordingRequested = true
            if !screenRecordingGranted {
                // Shows the system dialog only if no TCC record exists yet
                // (effectively once per install); silently returns false
                // afterwards, so fall through to the Settings deep link.
                if !CGRequestScreenCaptureAccess() {
                    openSystemSettings(for: .screenRecording)
                }
            }
        }
        beginPolling()
    }

    public func openSystemSettings(for permission: Permission) {
        let pane: String
        switch permission {
        case .accessibility: pane = "Privacy_Accessibility"
        case .screenRecording:
            pane = "Privacy_ScreenCapture"
            screenRecordingRequested = true
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
        beginPolling()
    }

    public func relaunchApp() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Observation

    @discardableResult
    public func observe(_ handler: @escaping (Set<Permission>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Polling

    private func beginPolling() {
        pollDeadline = Date().addingTimeInterval(180)
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let manager = PermissionsHolder.shared else { return }
                manager.probeScreenRecordingIfNeeded()
                manager.refresh()
                if let deadline = manager.pollDeadline, deadline < Date() {
                    manager.stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
    }

    private func probeScreenRecordingIfNeeded() {
        // Probe when awaiting a grant we requested, OR when we currently believe
        // it's granted (to catch a revocation). Both states have an existing TCC
        // decision, so the probe can't trigger a spurious system prompt. We do
        // NOT probe from the cold no-decision state — that would prompt.
        let shouldProbe = screenRecordingGranted || (screenRecordingRequested && !screenRecordingGranted)
        guard shouldProbe, !probeInFlight else { return }
        probeInFlight = true
        Task { [weak self] in
            let granted = await Self.probeScreenRecording()
            guard let self else { return }
            self.probeInFlight = false
            guard granted != self.screenRecordingGranted else { return }
            self.screenRecordingGranted = granted
            if granted { self.screenRecordingNeedsRelaunch = true }
            self.refresh()
        }
    }

    /// SCShareableContent succeeds iff Screen Recording is granted, and its
    /// answer is live mid-process. replayd can wedge, so race a timeout.
    private nonisolated static func probeScreenRecording() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Weak holder so C-style/Sendable closures (Timer, NotificationCenter) can
/// reach the manager without capturing non-Sendable state.
@MainActor
private enum PermissionsHolder {
    static weak var shared: PermissionsManager?
}
