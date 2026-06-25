// swift-tools-version: 6.2
import PackageDescription

// Panes — Windows UX creature comforts for macOS.
//
// Each feature is its own library target conforming to PanesCore.FeatureModule,
// so the build graph itself enforces modularity: features may depend on
// PanesCore, never on each other. Shared infrastructure (event taps, hotkeys,
// AX wrappers, Dock geometry, permissions) lives in PanesCore precisely
// because several modules need it — one CGEventTap for the whole app, not one
// per feature.
//
// MainActor default isolation: this app is an event-routing app whose work is
// inherently main-thread (AppKit, CGEventTap callbacks on the main run loop,
// Carbon hotkey dispatch). Pure-value types that must cross isolation opt out
// with `nonisolated`.

let moduleSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self)
]

let package = Package(
    name: "Panes",
    platforms: [
        // macOS 14 floor: SCScreenshotManager (one-shot captures) is 14.0+.
        // Supporting 12.3–13 would require an SCStream single-frame fallback.
        .macOS(.v14)
    ],
    targets: [
        .target(name: "PanesCore", swiftSettings: moduleSettings),
        .target(name: "WindowSnapping", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "KeyboardSnapping", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "DockPreviews", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "DockComfort", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "ClipboardHistory", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "ScreenshotTool", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "FinderCutPaste", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "AeroShake", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "AltTabSwitcher", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "WindowToDisplay", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .target(name: "DockNumberSwitch", dependencies: ["PanesCore"], swiftSettings: moduleSettings),
        .executableTarget(
            name: "Panes",
            dependencies: [
                "PanesCore",
                "WindowSnapping",
                "KeyboardSnapping",
                "DockPreviews",
                "DockComfort",
                "ClipboardHistory",
                "ScreenshotTool",
                "FinderCutPaste",
                "AeroShake",
                "AltTabSwitcher",
                "WindowToDisplay",
                "DockNumberSwitch",
            ],
            swiftSettings: moduleSettings
        ),
    ]
)
