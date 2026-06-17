import AppKit
import ApplicationServices
import PanesCore
import os

/// Hover detection with ZERO polling and zero per-mouse-move work.
///
/// The Dock marks whichever item the cursor is over as the "selected child"
/// of its AXList, and posts kAXSelectedChildrenChangedNotification on every
/// change (including to empty, when the cursor leaves). Subscribing an
/// AXObserver to that one notification means this module costs nothing
/// until the user actually touches the Dock.
///
/// The Dock process can restart (killall Dock, user relogin of Dock prefs),
/// which silently kills the AXObserver — a low-frequency health-check timer
/// watches for a pid change and resubscribes.
@MainActor
final class DockHoverMonitor: NSObject {
    private let dock: DockModel
    private let onHover: (DockModel.Item, NSRunningApplication) -> Void
    private let onLeave: () -> Void

    private var observer: AXObserver?
    private var observedDockPID: pid_t?
    private var healthCheckTimer: Timer?
    private var lastHoveredItemFrame: CGRect?
    private let log = Logger.panes("dock-hover")

    /// Set true while the cursor is over the preview panel itself so leaving
    /// the dock toward the panel doesn't dismiss it.
    var suppressLeave = false

    init(
        dock: DockModel,
        onHover: @escaping (DockModel.Item, NSRunningApplication) -> Void,
        onLeave: @escaping () -> Void
    ) {
        self.dock = dock
        self.onHover = onHover
        self.onLeave = onLeave
        super.init()
    }

    func start() {
        subscribe()
        let timer = Timer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(healthCheck),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1.0
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    func stop() {
        unsubscribe()
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        lastHoveredItemFrame = nil
    }

    // MARK: AXObserver lifecycle

    private func subscribe() {
        guard let pid = dock.dockPID, let list = dock.listElement() else {
            log.error("Dock AX list not reachable — Accessibility granted?")
            return
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, dockSelectionChangedCallback, &observer) == .success,
              let observer else {
            log.error("AXObserverCreate failed for Dock")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(
            observer,
            list.raw,
            kAXSelectedChildrenChangedNotification as CFString,
            refcon
        ) == .success else {
            log.error("AXObserverAddNotification failed for Dock list")
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        self.observer = observer
        observedDockPID = pid
    }

    private func unsubscribe() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        observedDockPID = nil
    }

    @objc private func healthCheck() {
        guard dock.dockPID != observedDockPID else { return }
        log.notice("Dock process changed — resubscribing hover observer")
        unsubscribe()
        subscribe()
    }

    // MARK: Selection handling (invoked by the C callback, main thread)

    fileprivate func selectionChanged() {
        guard
            let item = dock.selectedItem(),
            item.isApplication
        else {
            lastHoveredItemFrame = nil
            if !suppressLeave { onLeave() }
            return
        }
        guard item.isRunning, let app = dock.runningApplication(for: item) else {
            // Hovering a non-running app or folder: dismiss any open preview.
            lastHoveredItemFrame = nil
            if !suppressLeave { onLeave() }
            return
        }
        lastHoveredItemFrame = item.frame
        onHover(item, app)
    }
}

/// C-convention trampoline; the observer's run-loop source lives on the main
/// run loop, so this always executes on the main thread.
private nonisolated func dockSelectionChangedCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<DockHoverMonitor>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        monitor.selectionChanged()
    }
}
