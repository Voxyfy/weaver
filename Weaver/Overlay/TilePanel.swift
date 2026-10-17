import AppKit

/// Covers a cell whose window refused to get that small: shows the app's icon and name instead,
/// so the layout still reads correctly. Double-click to zoom into the window.
final class TilePanel: NSPanel {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var onOpen: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false

        let view = TileView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        view.onDoubleClick = { [weak self] in self?.onOpen() }

        icon.imageScaling = .scaleProportionallyUpOrDown
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            iconSize,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
        ])
        contentView = view
    }

    private lazy var iconSize = icon.widthAnchor.constraint(equalToConstant: 48)

    /// `compact` is the parked style: a small chip where one click opens the window.
    func show(rect: CGRect, window: AXWindow, compact: Bool = false, onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        (contentView as? TileView)?.singleClickOpens = compact
        icon.image = window.appIcon
        label.stringValue = window.title.isEmpty ? window.appName : window.title
        label.isHidden = !compact && (rect.height < 90 || rect.width < 90)
        iconSize.constant = compact ? 28 : 48
        label.font = .systemFont(ofSize: compact ? 11 : 12, weight: .medium)
        setFrame(Quartz.appKitRect(from: rect), display: true)
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}

final class TileView: NSView {
    var onDoubleClick: () -> Void = {}
    var singleClickOpens = false

    private var lastDown: TimeInterval = 0

    override func mouseDown(with event: NSEvent) {
        // Count clicks ourselves: a non-activating panel does not always get clickCount == 2.
        let now = ProcessInfo.processInfo.systemUptime
        if singleClickOpens || event.clickCount >= 2 || now - lastDown < 0.45 {
            lastDown = 0
            onDoubleClick()
        } else {
            lastDown = now
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
