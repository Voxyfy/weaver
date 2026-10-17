import AppKit
import ScreenCaptureKit

/// The picture that stands in for a window while it is dragged: a screenshot when Screen
/// Recording is allowed, otherwise the app's colour and icon. The real window stays put until
/// the drop, so the layout never has a hole in it mid-drag.
final class DragPreviewPanel: NSPanel {
    private let imageView = NSImageView()
    private let icon = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        alphaValue = 0.92

        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(imageView)
        view.addSubview(icon)
        contentView = view
    }

    func show(frame: CGRect, image: CGImage?, window: AXWindow) {
        setFrame(Quartz.appKitRect(from: frame), display: false)
        imageView.frame = contentView!.bounds
        if let image {
            imageView.image = NSImage(cgImage: image, size: frame.size)
            icon.isHidden = true
        } else {
            imageView.image = nil
            icon.image = window.appIcon
            icon.isHidden = false
            let side = min(96, frame.width * 0.3, frame.height * 0.3)
            icon.frame = NSRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)
        }
        if !isVisible { orderFrontRegardless() }
    }

    func move(to frame: CGRect) {
        setFrame(Quartz.appKitRect(from: frame), display: true)
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}

enum WindowSnapshot {
    /// A picture of one window through ScreenCaptureKit. Nil when the permission is missing
    /// or the capture fails; the caller then shows the icon block.
    static func capture(windowID: CGWindowID) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }
}
