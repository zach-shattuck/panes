import AppKit
import Carbon.HIToolbox
import PanesCore

public final class ScreenshotModule: FeatureModule {
    /// Preference key: when true, the hotkey freezes the screen and selects
    /// on the still instead of invoking the system picker.
    public static let freezeFramePreferenceKey = "screenshot.freezeFrame"

    public let metadata = ModuleMetadata(
        id: "screenshot",
        displayName: "Screenshot to Clipboard",
        category: "Clipboard & Screenshots",
        summary: "Grab part of the screen straight to the clipboard, ready to paste.",
        howToUse: "Press the shortcut below, then drag a box around what you want. It gets copied to the clipboard, so you can paste it with ⌘V. Turn on \"Freeze the screen while you select\" below if you want the screen to hold still while you choose the area, which helps when you're capturing menus or animations.",
        requiredPermissions: [.screenRecording],
        options: [
            .toggle(
                key: freezeFramePreferenceKey,
                title: "Freeze the screen while you select",
                detail: "Takes a snapshot the moment you press ⌘⇧S and lets you select on that frozen image, so menus, tooltips, and animations don't move while you frame your shot. When off, it uses the built-in macOS picker.",
                defaultOn: false
            )
        ],
        hotkeys: [
            HotkeyAction(
                id: "screenshot.capture",
                title: "Capture to clipboard",
                defaultSpec: HotkeyCenter.Spec(
                    keyCode: UInt32(kVK_ANSI_S),
                    carbonModifiers: UInt32(cmdKey | shiftKey)
                )
            )
        ]
    )

    private var hotkeyToken: HotkeyBindings.BindingToken?
    private weak var bindings: HotkeyBindings?
    private var preferences: PreferencesStore?
    private let captureService = CaptureService()
    private var activeSession: FreezeFrameSession?

    public init() {}

    public func start(context: ModuleContext) {
        preferences = context.preferences
        bindings = context.hotkeyBindings
        hotkeyToken = context.hotkeyBindings.bind("screenshot.capture") { [weak self] in
            self?.trigger()
        }
    }

    public func stop() {
        bindings?.unbind(hotkeyToken)
        hotkeyToken = nil
        activeSession?.cancel()
        activeSession = nil
        preferences = nil
    }

    private func trigger() {
        guard activeSession == nil else { return }
        let freeze = preferences?.bool(
            forKey: Self.freezeFramePreferenceKey,
            default: false
        ) ?? false

        if !freeze {
            captureService.standardInteractiveCapture()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let captures = await self.captureService.captureAllDisplays()
            guard !captures.isEmpty, self.activeSession == nil else { return }
            self.activeSession = FreezeFrameSession(captures: captures) { [weak self] image in
                if let image {
                    self?.captureService.copyToClipboard(image)
                }
                self?.activeSession = nil
            }
        }
    }
}
