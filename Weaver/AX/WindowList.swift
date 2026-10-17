import AppKit
import ApplicationServices

/// Finds the windows on screen and the window under the pointer.
enum WindowList {
    /// Standard, visible, non-minimized windows of other apps, front to back.
    static func onScreen() -> [AXWindow] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier
        var idsByPid: [pid_t: [CGWindowID]] = [:]
        var order: [CGWindowID] = []
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 60, (bounds["Height"] ?? 0) > 40 else { continue }
            idsByPid[pid, default: []].append(id)
            order.append(id)
        }
        var found: [CGWindowID: AXWindow] = [:]
        for (pid, ids) in idsByPid {
            let wanted = Set(ids)
            for w in windows(ofApp: pid) where wanted.contains(w.id) && w.isStandard {
                found[w.id] = w
            }
        }
        return order.compactMap { found[$0] }
    }

    static func windows(ofApp pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements.compactMap { AXWindow(element: $0, pid: pid) }
    }

    /// The app the user was working in. `open weaver://…` briefly activates Weaver itself even
    /// as a menu bar app, so the frontmost app is remembered and Weaver is skipped.
    nonisolated(unsafe) static var lastUserApp: NSRunningApplication?

    static func startTrackingFrontmost() {
        lastUserApp = NSWorkspace.shared.frontmostApplication
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                // Deactivation is the reliable one: the app that just lost focus to Weaver.
                lastUserApp = app
            }
        }
    }

    /// The key window of the app the user is working in, which is what they mean by "this window".
    static func focused() -> AXWindow? {
        var candidate = NSWorkspace.shared.frontmostApplication
        if candidate?.processIdentifier == ProcessInfo.processInfo.processIdentifier { candidate = lastUserApp }
        guard let app = candidate else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success else { return nil }
        let window = value as! AXUIElement
        return AXWindow(element: window, pid: app.processIdentifier)
    }

    /// Window under a Quartz point: hit-test the element, then climb to its window.
    static func window(at point: CGPoint) -> AXWindow? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        var value: CFTypeRef?
        var windowElement: AXUIElement? = nil
        if AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &value) == .success {
            windowElement = (value as! AXUIElement)
        } else {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success, (role as? String) == kAXWindowRole {
                windowElement = hit
            }
        }
        guard let windowElement, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AXWindow(element: windowElement, pid: pid)
    }
}
