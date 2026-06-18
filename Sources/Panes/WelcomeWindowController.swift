import AppKit

/// First-launch welcome: a short personal note from the author and the support
/// link. Shown once (gated by the first-launch flag in AppDelegate); "Get
/// Started" hands off to the Settings window so the user can turn features on.
@MainActor
final class WelcomeWindowController: NSWindowController {
    private let onGetStarted: () -> Void
    private static let supportURL = "https://www.paypal.biz/zachsoftworks"

    private static let bodyText = """
    I'm a life-long Windows user who switched to Mac and had a rough time. A lot of small, day-to-day things either didn't exist here or meant relearning habits I didn't want to. I still use both, so I set out to bridge the gap. Most Mac options felt like Windows features done the Apple way, so I made Windows features done the "right" way.

    Panes is a free passion project. If it helps you, please consider supporting it. The link is below, and in Settings any time.

    I hope you enjoy it, and that it makes switching to Mac a little less of a Pane.
    """

    init(onGetStarted: @escaping () -> Void) {
        self.onGetStarted = onGetStarted
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Panes"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let window else { return }
        let width: CGFloat = 500
        let textWidth: CGFloat = width - 56

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let heading = NSTextField(labelWithString: "Welcome to Panes!")
        heading.font = .systemFont(ofSize: 22, weight: .bold)

        let body = NSTextField(wrappingLabelWithString: Self.bodyText)
        body.font = .systemFont(ofSize: 13)
        body.textColor = .labelColor
        body.preferredMaxLayoutWidth = textWidth
        body.widthAnchor.constraint(equalToConstant: textWidth).isActive = true

        // "Support Panes" styled as a link, but a real borderless button so the
        // click reliably opens the PayPal page (a .link on a label is flaky).
        let link = NSButton(title: "Support Panes", target: self, action: #selector(openSupport))
        link.isBordered = false
        link.setButtonType(.momentaryChange)
        link.attributedTitle = NSAttributedString(
            string: "Support Panes",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            ]
        )

        let getStarted = NSButton(title: "Get Started", target: self, action: #selector(getStartedClicked))
        getStarted.bezelStyle = .rounded
        getStarted.keyEquivalent = "\r"
        getStarted.controlSize = .large

        let stack = NSStackView(views: [icon, heading, body, link, getStarted])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(18, after: heading)
        stack.setCustomSpacing(18, after: body)
        stack.setCustomSpacing(22, after: link)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    @objc private func openSupport() {
        if let url = URL(string: Self.supportURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func getStartedClicked() {
        window?.close()
        onGetStarted()
    }
}
