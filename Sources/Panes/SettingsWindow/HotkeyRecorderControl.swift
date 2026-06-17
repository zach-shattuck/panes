import AppKit
import Carbon.HIToolbox
import PanesCore

/// A row for one rebindable shortcut: its label, a click-to-record field
/// showing the current keys, and a reset-to-default button (shown only when
/// the shortcut has been changed).
///
/// Recording installs a local key monitor and suspends all app hotkeys via
/// `HotkeyBindings`, so a combo that overlaps an existing binding is captured
/// rather than fired. The new shortcut is persisted immediately; the running
/// module re-registers on its own.
final class HotkeyRecorderControl: NSView {
    /// Only one field records at a time; starting one cancels any other so a
    /// half-finished recording can't be left stuck swallowing keys.
    private static weak var activeRecorder: HotkeyRecorderControl?

    private let action: HotkeyAction
    private let bindings: HotkeyBindings
    private let field = NSButton()
    private let resetButton = NSButton()
    private var monitor: Any?

    private var recording = false {
        didSet { refresh() }
    }

    init(action: HotkeyAction, bindings: HotkeyBindings) {
        self.action = action
        self.bindings = bindings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: action.title)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        field.bezelStyle = .rounded
        field.setButtonType(.momentaryPushIn)
        field.controlSize = .regular
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.target = self
        field.action = #selector(toggleRecording)
        field.translatesAutoresizingMaskIntoConstraints = false

        resetButton.image = NSImage(
            systemSymbolName: "arrow.uturn.backward",
            accessibilityDescription: "Reset shortcut"
        )
        resetButton.imagePosition = .imageOnly
        resetButton.isBordered = false
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToDefault)
        resetButton.toolTip = "Reset to default"
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(field)
        addSubview(resetButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: field.leadingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            field.trailingAnchor.constraint(equalTo: resetButton.leadingAnchor, constant: -6),
            resetButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            resetButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Display

    private func refresh() {
        if recording {
            field.title = "Type shortcut…"
            field.contentTintColor = .controlAccentColor
        } else {
            let spec = bindings.spec(for: action.id) ?? action.defaultSpec
            // Space the glyphs out — ⌃⌥⌘ etc. read as a cramped blob otherwise.
            let combo = HotkeySymbols.string(spec)
            let attributed = NSMutableAttributedString(string: combo, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
            let length = (combo as NSString).length
            if length > 1 {
                // Kern adds space AFTER each glyph; skip the last so the text
                // stays centered.
                attributed.addAttribute(.kern, value: 3.0, range: NSRange(location: 0, length: length - 1))
            }
            field.attributedTitle = attributed
            field.contentTintColor = nil
        }
        resetButton.isHidden = recording || !bindings.isCustomized(action.id)
    }

    // MARK: Recording

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard monitor == nil else { return }
        Self.activeRecorder?.stopRecording()
        Self.activeRecorder = self
        recording = true
        bindings.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown { return self.capture(event) }
            return nil // swallow modifier-only changes while recording
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        bindings.endRecording()
        recording = false
    }

    /// Handle a key press during recording. Returns nil to swallow the event.
    private func capture(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }
        let carbon = HotkeySymbols.carbonModifiers(from: event.modifierFlags)
        // Require at least one of Command/Option/Control so a plain key (or
        // Shift+key, which is just a typed character) can't hijack typing.
        let needed = UInt32(cmdKey | optionKey | controlKey)
        guard carbon & needed != 0 else {
            field.title = "Add ⌘ ⌥ or ⌃"
            return nil
        }
        bindings.setSpec(
            HotkeyCenter.Spec(keyCode: UInt32(event.keyCode), carbonModifiers: carbon),
            for: action.id
        )
        stopRecording()
        return nil
    }

    @objc private func resetToDefault() {
        bindings.reset(action.id)
        refresh()
    }

    /// Stop recording if the row is torn down (detail re-render or window close)
    /// so the local monitor and hotkey suspension never outlive the view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, monitor != nil { stopRecording() }
    }
}
