import Cocoa

/// Borderless banner shown near the top of *every* screen while locked, so
/// the user never mistakes the lock for a frozen Mac and knows how to get
/// back in — including when the meeting is on a secondary display. Fully
/// transparent (just shadowed text, no background panel) so it doesn't
/// obscure whatever's underneath, and click-through so it never blocks
/// mouse interaction with the app behind it.
final class OverlayWindow {
    private var panels: [NSPanel] = []

    init() {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        panels = screens.map { Self.makePanel(on: $0.frame) }
        if panels.isEmpty {
            // No screen information at all (headless/odd state) — fall back
            // to a sensible rect so the lock still shows something.
            panels = [Self.makePanel(on: NSRect(x: 0, y: 0, width: 800, height: 600))]
        }
    }

    private static func makePanel(on screenFrame: NSRect) -> NSPanel {
        let label = NSTextField(labelWithString: "🔒 Keyboard Locked — Unlock in menu dropdown")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        label.shadow = shadow
        label.sizeToFit()

        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 8
        let width = label.frame.width + horizontalPadding * 2
        let height = label.frame.height + verticalPadding * 2
        label.frame.origin = NSPoint(x: horizontalPadding, y: verticalPadding)

        let origin = NSPoint(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height - 40)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: height))

        let panel = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(label)
        panel.contentView = container
        return panel
    }

    func show() {
        panels.forEach { $0.orderFrontRegardless() }
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}
