import AppKit

@main
enum PanesMain {
    static func main() {
        let app = NSApplication.shared
        // Menu-bar-only app. In a real .app bundle this is LSUIElement=YES in
        // Info.plist; setting the activation policy in code keeps the bare
        // SwiftPM executable dock-free during development too.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
