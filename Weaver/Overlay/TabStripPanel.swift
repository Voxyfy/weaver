import AppKit

/// The strip above a tab group: one chip per window, the front one highlighted, a close
/// button on hover that floats the window out of the group.
final class TabStripPanel: NSPanel {
    private let stripView = TabStripView()
    private let glass = NSVisualEffectView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 10
        glass.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        contentView = glass
        stripView.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stripView)
        NSLayoutConstraint.activate([
            stripView.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stripView.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stripView.topAnchor.constraint(equalTo: glass.topAnchor),
            stripView.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
    }

    func update(strip: TabStrip, windows: [AXWindow], active: CGWindowID?,
                onSelect: @escaping (CGWindowID) -> Void, onClose: @escaping (CGWindowID) -> Void) {
        setFrame(Quartz.appKitRect(from: strip.rect), display: true)
        stripView.configure(windows: windows, active: active, onSelect: onSelect, onClose: onClose)
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}

final class TabStripView: NSView {
    private var chips: [TabChip] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.35).cgColor
        layer?.cornerRadius = 10
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    required init?(coder: NSCoder) { nil }

    func configure(windows: [AXWindow], active: CGWindowID?, onSelect: @escaping (CGWindowID) -> Void, onClose: @escaping (CGWindowID) -> Void) {
        chips.forEach { $0.removeFromSuperview() }
        chips = windows.map { w in
            let chip = TabChip(window: w, isActive: w.id == active)
            chip.onSelect = { onSelect(w.id) }
            chip.onClose = { onClose(w.id) }
            addSubview(chip)
            return chip
        }
        layoutChips()
    }

    override func layout() {
        super.layout()
        layoutChips()
    }

    /// Chips sit in the middle of the strip, like a browser's tab row centred on the title.
    private func layoutChips() {
        let count = max(chips.count, 1)
        let width = min(200, (bounds.width - 12) / CGFloat(count) - 6)
        let total = CGFloat(chips.count) * width + CGFloat(max(chips.count - 1, 0)) * 6
        var x = max(6, (bounds.width - total) / 2)
        for chip in chips {
            chip.frame = NSRect(x: x, y: 5, width: width, height: bounds.height - 10)
            x += width + 6
        }
    }
}

final class TabChip: NSView {
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let close = NSButton(title: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private let isActive: Bool

    init(window: AXWindow, isActive: Bool) {
        self.isActive = isActive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = (isActive ? NSColor.white.withAlphaComponent(0.16) : NSColor.clear).cgColor
        layer?.borderWidth = isActive ? 0.5 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor

        icon.image = window.appIcon
        icon.imageScaling = .scaleProportionallyDown
        title.stringValue = window.title.isEmpty ? window.appName : window.title
        title.font = .systemFont(ofSize: 12, weight: isActive ? .semibold : .regular)
        title.textColor = isActive ? .labelColor : .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        close.bezelStyle = .inline
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Float out")
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        close.isHidden = true
        for v in [icon, title, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16), close.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false }
    override func mouseExited(with event: NSEvent) { close.isHidden = true }
    override func mouseDown(with event: NSEvent) { onSelect() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeTapped() { onClose() }
}
