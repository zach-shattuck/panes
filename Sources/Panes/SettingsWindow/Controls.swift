import AppKit

/// NSSwitch with a closure instead of target/action plumbing.
final class ClosureSwitch: NSSwitch {
    private let onToggle: (Bool) -> Void

    init(isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        state = isOn ? .on : .off
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func changed() { onToggle(state == .on) }
}

/// Borderless text button with a closure.
final class ClosureButton: NSButton {
    private let onClick: () -> Void

    init(title: String, style: NSButton.BezelStyle = .rounded, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        bezelStyle = style
        setButtonType(.momentaryPushIn)
        controlSize = .small
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func clicked() { onClick() }
}

/// NSSlider with a closure.
final class ClosureSlider: NSSlider {
    private let onChange: (Double) -> Void

    init(value: Double, min: Double, max: Double, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        minValue = min
        maxValue = max
        doubleValue = value
        isContinuous = true
        controlSize = .small
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func changed() { onChange(doubleValue) }
}

/// NSSegmentedControl (pick-one) with a closure.
final class ClosureSegmented: NSSegmentedControl {
    private let onSelect: (Int) -> Void

    init(labels: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        segmentStyle = .rounded
        trackingMode = .selectOne
        segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            setLabel(label, forSegment: index)
            setWidth(0, forSegment: index) // 0 = size to fit the label
        }
        selectedSegment = max(0, min(selected, labels.count - 1))
        controlSize = .small
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    @objc private func changed() { onSelect(selectedSegment) }
}

/// Top-down laid-out document view for a scroll view.
final class FlippedStack: NSStackView {
    override var isFlipped: Bool { true }
}
