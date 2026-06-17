import AppKit
import PanesCore

/// A user-defined snap layout: a named set of zones in normalized layout space
/// (origin top-left, 0–1 on both axes — the same space as `SnapLayoutOption`).
/// Persisted as JSON in preferences and surfaced in the drag-to-top palette
/// alongside the built-in presets.
public struct ZoneLayout: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var zones: [Zone]

    /// One zone, stored as plain doubles so the JSON is stable and obvious.
    public struct Zone: Codable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }

        public init(_ rect: CGRect) {
            self.init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
        }

        public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    public init(id: UUID = UUID(), name: String, zones: [Zone]) {
        self.id = id
        self.name = name
        self.zones = zones
    }
}

/// Load/save the user's custom layouts. Stored as a JSON string under one
/// preference key so the WindowSnapping module (which feeds them into the
/// palette) and the Settings editor share one source of truth.
public enum CustomLayoutStore {
    public static let key = "window-snapping.customLayouts"

    public static func load(_ preferences: PreferencesStore) -> [ZoneLayout] {
        guard let json = preferences.string(forKey: key),
              let data = json.data(using: .utf8),
              let layouts = try? JSONDecoder().decode([ZoneLayout].self, from: data)
        else { return [] }
        return layouts
    }

    public static func save(_ layouts: [ZoneLayout], _ preferences: PreferencesStore) {
        guard let data = try? JSONEncoder().encode(layouts),
              let json = String(data: data, encoding: .utf8)
        else { return }
        preferences.set(json, forKey: key)
    }
}

extension SnapLayoutOption {
    /// Adapt a saved layout to the palette's option type.
    init(_ layout: ZoneLayout) {
        self.init(zones: layout.zones.map(\.rect))
    }
}
