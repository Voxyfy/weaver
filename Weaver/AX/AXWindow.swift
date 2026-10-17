import AppKit
import ApplicationServices

/// Maps an accessibility element to its CGWindowID. Private, but every Mac window manager
/// (yabai, AeroSpace, Amethyst) relies on it; there is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Everything in Weaver's model uses Quartz coordinates: origin at the top-left of the primary
/// display, y growing downward. That is what the Accessibility API and CGWindowList speak.
/// AppKit's bottom-left frames are converted only where we create our own panels.
enum Quartz {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func rect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    static func appKitRect(from r: CGRect) -> CGRect {
        CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    /// Usable area of a screen (below the menu bar, above the Dock) in Quartz coordinates.
    static func visibleFrame(of screen: NSScreen) -> CGRect {
        rect(fromAppKit: screen.visibleFrame)
    }
}

/// A window of another application, driven through the Accessibility API.
final class AXWindow: Hashable, CustomStringConvertible {
    let element: AXUIElement
    let pid: pid_t
    let id: CGWindowID

    init?(element: AXUIElement, pid: pid_t) {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        self.element = element
        self.pid = pid
        self.id = wid
    }

    var title: String { attribute(kAXTitleAttribute) as String? ?? "" }
    var subrole: String { attribute(kAXSubroleAttribute) as String? ?? "" }
    var isStandard: Bool { subrole == kAXStandardWindowSubrole }
    var isMinimized: Bool { (attribute(kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false }
    /// Dead only when the element itself is gone. A busy app can time out or refuse for a
    /// moment; treating that as "closed" would throw the window out of the tree.
    var isAlive: Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return err != .invalidUIElement
    }

    var appName: String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App" }
    var appIcon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    var frame: CGRect {
        get {
            guard let p = point(kAXPositionAttribute), let s = size(kAXSizeAttribute) else { return .zero }
            return CGRect(origin: p, size: s)
        }
        set { setFrame(newValue) }
    }

    /// Size first, then position, then size again: apps clamp to their minimum size, and the
    /// position they accept depends on the size they end up with.
    func setFrame(_ r: CGRect) {
        let app = AXUIElementCreateApplication(pid)
        // Some apps animate every AX move when "enhanced user interface" is on; switch it off
        // for the duration so the window lands immediately.
        var enhanced: CFTypeRef?
        let hadEnhanced = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhanced) == .success
            && (enhanced as? NSNumber)?.boolValue == true
        if hadEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if hadEnhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        var size = r.size
        var origin = r.origin
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) }
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    func unminimize() {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }

    // MARK: - Attribute helpers

    private func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func point(_ name: String) -> CGPoint? {
        guard let value: AXValue = attribute(name) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    private func size(_ name: String) -> CGSize? {
        guard let value: AXValue = attribute(name) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    static func == (lhs: AXWindow, rhs: AXWindow) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var description: String { "\(appName) “\(title)” #\(id)" }
}

/// Named AXPermission, not Accessibility: that name is taken by Apple's framework module.
enum AXPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows Apple's own prompt once; the user then flips the switch in System Settings.
    static func requestIfNeeded() {
        guard !isTrusted else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
