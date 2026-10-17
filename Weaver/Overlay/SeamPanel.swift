import AppKit

/// An invisible strip over the gap between two docked windows. Dragging it resizes both.
final class SeamPanel: NSPanel {
    private let seamView: SeamView

    init(seam: Seam, onDrag: @escaping (CGFloat) -> Void) {
        seamView = SeamView(axis: seam.axis, length: seam.parentLength, onDrag: onDrag)
        super.init(contentRect: Quartz.appKitRect(from: seam.rect),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        // Frosted glass under the handle: the gap shows the wallpaper blurred instead of raw.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 3
        contentView = glass
        seamView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(seamView)
        NSLayoutConstraint.activate([
            seamView.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            seamView.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            seamView.topAnchor.constraint(equalTo: glass.topAnchor),
            seamView.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        orderFrontRegardless()
    }

    /// Driven from a global mouse-moved monitor: tracking areas alone do not fire reliably
    /// on a non-activating panel while another app is active.
    func setHovered(_ on: Bool) { seamView.hovered = on }

    func update(seam: Seam, onDrag: @escaping (CGFloat) -> Void) {
        setFrame(Quartz.appKitRect(from: seam.rect), display: false)
        seamView.axis = seam.axis
        seamView.length = seam.parentLength
        seamView.onDrag = onDrag
        seamView.resetCursorRects()
    }
}

final class SeamView: NSView {
    var axis: Axis
    var length: CGFloat
    var onDrag: (CGFloat) -> Void
    private var last: NSPoint = .zero
    private var tracking: NSTrackingArea?
    /// The handle shows on hover and while dragging, so the gap reads as something you can grab.
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { needsDisplay = true } }

    init(axis: Axis, length: CGFloat, onDrag: @escaping (CGFloat) -> Void) {
        self.axis = axis
        self.length = length
        self.onDrag = onDrag
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || dragging else { return }
        // A small white pill in the middle of the gap, like a drawer handle.
        let thickness: CGFloat = 4
        let span: CGFloat = min(36, (axis == .horizontal ? bounds.height : bounds.width) - 8)
        let rect = axis == .horizontal
            ? NSRect(x: bounds.midX - thickness / 2, y: bounds.midY - span / 2, width: thickness, height: span)
            : NSRect(x: bounds.midX - span / 2, y: bounds.midY - thickness / 2, width: span, height: thickness)
        NSColor.white.withAlphaComponent(dragging ? 1 : 0.85).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        last = NSEvent.mouseLocation
        dragging = true
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        // AppKit's y grows upward; the layout's grows downward, hence the sign flip.
        let delta = axis == .horizontal ? now.x - last.x : -(now.y - last.y)
        last = now
        guard length > 0 else { return }
        onDrag(delta / length)
    }
}
