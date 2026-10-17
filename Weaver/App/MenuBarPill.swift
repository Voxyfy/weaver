import AppKit

/// The menu bar control: back, forward, Desktop, everything, and the Weaver menu. One pill,
/// drawn into the status item's button.
final class MenuBarPill: NSView {
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onDesktop: () -> Void = {}
    var onEverything: () -> Void = {}
    var onMenu: (NSView) -> Void = { _ in }

    static let width: CGFloat = 150

    private var segments: [(frame: NSRect, action: () -> Void)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let items: [(String, String)] = [
            ("chevron.left", "Back"),
            ("chevron.right", "Forward"),
            ("rectangle.bottomhalf.inset.filled", "Hide or show the Desktop"),
            ("square.grid.2x2", "Show everything"),
            ("square.on.square.dashed", "Weaver menu"),
        ]
        var x: CGFloat = 4
        for (symbol, help) in items {
            let icon = NSImageView(frame: NSRect(x: x, y: 2, width: 26, height: 18))
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = .labelColor
            icon.toolTip = help
            addSubview(icon)
            x += 29
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The status bar button swallows the real click and replays one at its centre, so the
    /// segment is picked from the pointer's actual screen position instead.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let index = Int((point.x - 4) / 29)
        switch index {
        case 0: onBack()
        case 1: onForward()
        case 2: onDesktop()
        case 3: onEverything()
        case 4: onMenu(self)
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu(self) }

    /// Children are pictures; the pill itself handles every click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
}
