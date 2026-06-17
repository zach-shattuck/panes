import AppKit
import ApplicationServices

/// Thin, typed wrapper over AXUIElement.
///
/// All AX coordinates are in Core Graphics "global display" space: origin at
/// the TOP-LEFT of the primary display, y growing downward — the same space
/// CGEvent locations use, and the opposite vertical convention from NSScreen/
/// NSWindow. Convert at the AppKit boundary with `ScreenGeometry`.
@MainActor
public struct AXElement {
    public let raw: AXUIElement

    public init(_ raw: AXUIElement) {
        self.raw = raw
    }

    public static var systemWide: AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public var pid: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(raw, &pid) == .success else { return nil }
        return pid
    }

    // MARK: Typed attribute access

    public func value(_ attribute: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref
    }

    public func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    public func bool(_ attribute: String) -> Bool? {
        value(attribute) as? Bool
    }

    public func url(_ attribute: String) -> URL? {
        value(attribute) as? URL
    }

    public func element(_ attribute: String) -> AXElement? {
        guard let ref = value(attribute), CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return nil
        }
        return AXElement(ref as! AXUIElement)
    }

    public func elements(_ attribute: String) -> [AXElement] {
        guard let array = value(attribute) as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    public func point(_ attribute: String) -> CGPoint? {
        guard let ref = value(attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    public func size(_ attribute: String) -> CGSize? {
        guard let ref = value(attribute), CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: Common attributes

    public var role: String? { string(kAXRoleAttribute) }
    public var subrole: String? { string(kAXSubroleAttribute) }
    public var title: String? { string(kAXTitleAttribute) }
    public var children: [AXElement] { elements(kAXChildrenAttribute) }
    public var parent: AXElement? { element(kAXParentAttribute) }

    /// Frame in CG top-left global coordinates.
    public var frame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let size = size(kAXSizeAttribute) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Mutation

    @discardableResult
    public func set(_ attribute: String, to value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(raw, attribute as CFString, value) == .success
    }

    @discardableResult
    public func set(_ attribute: String, point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return set(attribute, to: value)
    }

    @discardableResult
    public func set(_ attribute: String, size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return set(attribute, to: value)
    }

    @discardableResult
    public func set(_ attribute: String, bool: Bool) -> Bool {
        set(attribute, to: bool as CFBoolean)
    }

    @discardableResult
    public func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(raw, action as CFString) == .success
    }

    // MARK: Hit testing

    /// Element at a point in CG top-left global coordinates. Called on the
    /// system-wide element this resolves across apps; on an application
    /// element it resolves within that app only (used for Dock hit tests).
    public func elementAtPosition(_ point: CGPoint) -> AXElement? {
        var ref: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(raw, Float(point.x), Float(point.y), &ref)
        guard error == .success, let ref else { return nil }
        return AXElement(ref)
    }
}
