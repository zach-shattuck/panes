import AppKit
import os

/// The single owner of global input monitoring for the entire app.
///
/// Two delivery mechanisms, chosen per subscription:
///
///  - PASSIVE (`wantsConsume: false`): an `NSEvent` global monitor. Mouse
///    monitors require NO TCC permission and are delivered asynchronously
///    after the system has handled the event — they cannot add input
///    latency, no matter how slow our handler is. (Caveat inherited from
///    AppKit: global monitors never see our OWN app's events, which is fine
///    for watching other apps' windows and the Dock.)
///
///  - CONSUMING (`wantsConsume: true`): an active CGEventTap
///    (`.defaultTap`, session level), the only mechanism that can swallow an
///    event before its target sees it. Requires Accessibility —
///    `CGEvent.tapCreate` returns nil without it (surfaced via
///    `isInstalled`; ModuleRegistry starts consuming modules only after the
///    grant, and `refresh()` re-attempts). The tap sits synchronously in
///    system-wide event delivery for its masked types, so consuming
///    handlers must be CHEAP on the miss path; a slow callback makes the
///    system disable the tap (re-enabled here, but consumed events leak
///    through while disabled).
///
/// Regardless of how many modules run, there is at most ONE monitor and ONE
/// tap, each carrying the union mask of its subscribers, rebuilt as modules
/// start/stop and torn down when unused.
@MainActor
public final class EventTapHub {
    public enum Verdict: Sendable {
        case pass
        /// Swallow the event (only honored for subscriptions registered with
        /// `wantsConsume: true`).
        case consume
    }

    public typealias Handler = (_ type: CGEventType, _ event: CGEvent) -> Verdict

    public nonisolated struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Subscriber {
        let token: Token
        let mask: CGEventMask
        let wantsConsume: Bool
        let handler: Handler
    }

    private final class Tap {
        let port: CFMachPort
        let source: CFRunLoopSource
        init(port: CFMachPort, source: CFRunLoopSource) {
            self.port = port
            self.source = source
        }
    }

    private var subscribers: [Subscriber] = []
    private var activeTap: Tap?
    private var globalMonitor: Any?
    private let log = Logger.panes("event-hub")

    public init() {}

    /// True when every needed mechanism is installed (or none is needed).
    public private(set) var isInstalled = true

    // MARK: Subscription

    @discardableResult
    public func subscribe(
        to types: [CGEventType],
        wantsConsume: Bool = false,
        handler: @escaping Handler
    ) -> Token {
        let token = Token(id: UUID())
        let mask = types.reduce(into: CGEventMask(0)) { $0 |= CGEventMask(1) << CGEventMask($1.rawValue) }
        subscribers.append(Subscriber(token: token, mask: mask, wantsConsume: wantsConsume, handler: handler))
        rebuild()
        return token
    }

    public func unsubscribe(_ token: Token) {
        subscribers.removeAll { $0.token == token }
        rebuild()
    }

    /// Re-attempt installation (call after Accessibility is granted).
    public func refresh() {
        rebuild()
    }

    // MARK: Installation

    private func rebuild() {
        tearDown()

        let consumeMask = subscribers.filter(\.wantsConsume).reduce(CGEventMask(0)) { $0 | $1.mask }
        // Consume-capable types are delivered via the tap only, so each
        // event reaches each subscriber exactly once.
        let passiveMask = subscribers.reduce(CGEventMask(0)) { $0 | $1.mask } & ~consumeMask

        isInstalled = true
        if consumeMask != 0 {
            activeTap = makeTap(mask: consumeMask)
            if activeTap == nil {
                isInstalled = false
                log.error("CGEvent.tapCreate failed — Accessibility not granted?")
            }
        }
        if passiveMask != 0 {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: nsEventMask(fromCGMask: passiveMask)
            ) { nsEvent in
                MainActor.assumeIsolated {
                    guard let hub = EventHubHolder.shared, let cgEvent = nsEvent.cgEvent else { return }
                    _ = hub.dispatch(type: cgEvent.type, event: cgEvent)
                }
            }
            EventHubHolder.shared = self
        }
    }

    private func tearDown() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap.port, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
            activeTap = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func makeTap(mask: CGEventMask) -> Tap? {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return Tap(port: port, source: source)
    }

    /// CGEventMask and NSEvent.EventTypeMask use the same per-type bit
    /// positions (both are `1 << eventType.rawValue`).
    private nonisolated func nsEventMask(fromCGMask mask: CGEventMask) -> NSEvent.EventTypeMask {
        NSEvent.EventTypeMask(rawValue: UInt64(mask))
    }

    // MARK: Dispatch

    /// Returns true when the event should be swallowed. Runs on the main
    /// thread for both delivery paths.
    fileprivate func dispatch(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disabled the tap (slow callback or secure input).
            log.warning("event tap disabled (\(type.rawValue)); re-enabling")
            if let tap = activeTap { CGEvent.tapEnable(tap: tap.port, enable: true) }
            return false
        }

        let bit = CGEventMask(1) << CGEventMask(type.rawValue)
        var consumed = false
        for subscriber in subscribers where subscriber.mask & bit != 0 {
            if subscriber.handler(type, event) == .consume, subscriber.wantsConsume {
                consumed = true
            }
        }
        return consumed
    }
}

/// C-convention trampoline for the consuming tap. The tap source lives on
/// the main run loop, so this is always invoked on the main thread —
/// `assumeIsolated` is a dynamic assertion of that, not a hop.
private nonisolated func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let hub = Unmanaged<EventTapHub>.fromOpaque(refcon).takeUnretainedValue()
    // CGEvent is not Sendable; this never leaves the main thread.
    nonisolated(unsafe) let unsafeEvent = event
    let consumed = MainActor.assumeIsolated {
        hub.dispatch(type: type, event: unsafeEvent)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

/// Weak holder so the @Sendable NSEvent monitor closure can reach the hub
/// without capturing non-Sendable state.
@MainActor
private enum EventHubHolder {
    static weak var shared: EventTapHub?
}
