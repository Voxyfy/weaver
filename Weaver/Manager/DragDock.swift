import AppKit

/// Dock by dragging. The drag is taken over as soon as it starts: the real window stays in
/// its place, a picture of it follows the pointer, and on the drop the window lands in a cell,
/// a tab group, or wherever the picture was let go. Needs an event tap (Accessibility).
@MainActor
final class DragDockController {
    private enum Zone {
        case screenEdge(Side, NSScreen)
        case windowEdge(Side, AXWindow)
        case tabGroup(AXWindow)
        case desktopEdge(Side, CGRect)   // split the Desktop cell
        case desktopFill(CGRect)         // take the Desktop cell's place
    }

    private var tap: CFMachPort?
    private var monitors: [Any] = []

    // The press that may become a drag.
    private var candidate: (window: AXWindow, start: CGPoint, frame: CGRect)?
    private var takenOver = false
    private var grabOffset = CGPoint.zero
    private var previewFrame = CGRect.zero
    private var zone: Zone?
    private var middleHover: (id: CGWindowID, since: TimeInterval)?
    private var holdTimer: Timer?
    /// Finishes a drag whose mouse-up never reached the tap (tap paused, event lost): as soon
    /// as the button is seen released, the drop happens where the pointer is.
    private var watchdog: Timer?
    /// Esc is claimed as a hot key only while a drag is in flight; Carbon hot keys need no
    /// extra permission, unlike a global key monitor.
    private let escKey = HotKeyCenter()
    private var lastClick: (id: CGWindowID, time: TimeInterval, point: CGPoint)?
    /// Screen edges the pointer has been away from during this drag; only those can dock.
    /// Otherwise grabbing a window that sits at the top of the screen docks it at once.
    private var armedEdges: Set<Side> = []

    private let highlight = HighlightPanel()
    private let preview = DragPreviewPanel()

    private var edgeBand: CGFloat { Preferences.shared.edgeBand }
    private var groupHoldSeconds: TimeInterval { Preferences.shared.groupHold }
    private let windowBand: CGFloat = 0.3
    private let titleBarHeight: CGFloat = 40
    private let trafficLightsWidth: CGFloat = 80
    /// Marks the mouse-up Weaver posts to end the app's own drag, so the tap lets it through.
    private static let syntheticTag: Int64 = 0x5745_4156

    func start() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.mouseMoved.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // The tap source lives on the main run loop, so this is already the main thread.
            nonisolated(unsafe) let ev = event
            let consumed: Bool = MainActor.assumeIsolated {
                dragDockShared?.handle(type: type, event: ev) ?? false
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        dragDockShared = self
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: mask, callback: callback, userInfo: nil) {
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            DebugLog.write("event tap active")
        } else if tapAttempts < 10 {
            // Right after launch the permission can take a moment to apply; try again shortly.
            tapAttempts += 1
            DebugLog.write("event tap unavailable, retry \(tapAttempts)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
        } else {
            DebugLog.write("event tap unavailable, using monitors")
            startMonitors()
        }
    }

    private var tapAttempts = 0

    private var pointer: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: Quartz.primaryHeight - p.y)
    }

    // MARK: - Event tap

    /// Returns true when the event is Weaver's and must not reach the app under the pointer.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            DebugLog.write("event tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .mouseMoved:
            WindowManager.shared.hoverSeams(at: event.location)
            return false
        case .leftMouseDown:
            mouseDown(at: event.location, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
            return false
        case .leftMouseDragged:
            return mouseDragged(at: event.location)
        case .leftMouseUp:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return false }
            if takenOver { DebugLog.write("drag mouseUp at \(event.location)") }
            return mouseUp(at: event.location)
        default:
            return false
        }
    }

    private func mouseDown(at point: CGPoint, clickCount: Int) {
        candidate = nil
        takenOver = false
        zone = nil
        guard let window = WindowList.window(at: point), window.isStandard,
              !Preferences.shared.isExcluded(pid: window.pid) else { DebugLog.write("mouseDown: no window at \(point)"); return }
        let frame = window.frame
        // Only the title bar starts a dock drag: not the traffic lights, and not the outer rim,
        // which is the resize handle.
        let rim: CGFloat = 10
        guard point.y - frame.minY < titleBarHeight, point.y - frame.minY > rim,
              point.x - frame.minX > trafficLightsWidth, frame.maxX - point.x > rim else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.id == window.id, now - last.time < 0.45,
           hypot(point.x - last.point.x, point.y - last.point.y) < 8 {
            lastClick = nil
            if WindowManager.shared.isManaged(window.id) {
                WindowManager.shared.zoom(window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WindowManager.shared.apply() }
            }
            return
        }
        lastClick = (window.id, now, point)
        candidate = (window, point, frame)
        DebugLog.write("drag candidate \(window)")
    }

    /// Returns true when the event was consumed (the drag is ours).
    private func mouseDragged(at point: CGPoint) -> Bool {
        guard let candidate else { return false }
        if !takenOver {
            guard hypot(point.x - candidate.start.x, point.y - candidate.start.y) > 12 else { return false }
            // Wait for the app to show what this press does: a size change is a resize (not
            // ours), a position change is a move (ours). Until one happens, keep watching.
            let now = candidate.window.frame
            let resized = abs(now.width - candidate.frame.width) > 2 || abs(now.height - candidate.frame.height) > 2
            let moved = abs(now.minX - candidate.frame.minX) > 2 || abs(now.minY - candidate.frame.minY) > 2
            if resized {
                DebugLog.write("drag ignored: resize")
                self.candidate = nil
                return false
            }
            guard moved else { return false }
            takeOver(candidate, at: point)
        }
        previewFrame.origin = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
        preview.move(to: previewFrame)
        updateZone(at: point, dragged: candidate.window)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: groupHoldSeconds + 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.takenOver, let c = self.candidate else { return }
                self.updateZone(at: self.pointer, dragged: c.window)
            }
        }
        return true
    }

    private func takeOver(_ c: (window: AXWindow, start: CGPoint, frame: CGRect), at point: CGPoint) {
        DebugLog.write("drag takeover \(c.window)")
        takenOver = true
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.takenOver else { return }
                // Session state covers posted events too, which NSEvent.pressedMouseButtons misses.
                if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                    DebugLog.write("drag watchdog: button up, dropping")
                    _ = self.mouseUp(at: self.pointer)
                }
            }
        }
        escKey.register(.init(code: KeyCode.escape, modifiers: 0)) { [weak self] in self?.cancelDrag() }
        WindowManager.shared.isUserDragging = true
        // End the app's own drag with a mouse-up it believes in, then put the window back.
        // Delivered to that app only, so the system still knows the button is down and the
        // watchdog can tell a lost mouse-up from a drag in progress.
        if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            up.postToPid(c.window.pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { c.window.setFrame(c.frame) }
        // A picture under the pointer; the grab point keeps its place on the picture.
        let scale: CGFloat = 0.5
        previewFrame = CGRect(x: 0, y: 0, width: c.frame.width * scale, height: c.frame.height * scale)
        grabOffset = CGPoint(x: (point.x - c.frame.minX) * scale, y: (point.y - c.frame.minY) * scale)
        previewFrame.origin = CGPoint(x: point.x - grabOffset.x, y: point.y - grabOffset.y)
        preview.show(frame: previewFrame, image: nil, window: c.window)
        let id = c.window.id
        Task { [weak self] in
            guard let image = await WindowSnapshot.capture(windowID: id), let self, self.takenOver,
                  self.candidate?.window.id == id else { return }
            self.preview.show(frame: self.previewFrame, image: image, window: c.window)
        }
    }

    /// Esc: the window stays where it was, nothing docks.
    private func cancelDrag() {
        guard takenOver else { return }
        DebugLog.write("drag cancelled")
        zone = nil
        _ = mouseUpCore(at: nil)
    }

    private func mouseUp(at point: CGPoint) -> Bool { mouseUpCore(at: point) }

    /// `point == nil` means cancel: no move at all.
    private func mouseUpCore(at point: CGPoint?) -> Bool {
        defer {
            candidate = nil; takenOver = false; zone = nil; middleHover = nil; armedEdges = []
            holdTimer?.invalidate(); watchdog?.invalidate(); watchdog = nil
            escKey.unregisterAll()
        }
        guard let candidate, takenOver else { return false }
        guard let point else {
            preview.hide(); highlight.hide(); WindowManager.shared.isUserDragging = false
            return true
        }
        DebugLog.write("drag drop zone=\(String(describing: zone))")
        preview.hide()
        highlight.hide()
        WindowManager.shared.isUserDragging = false
        let wm = WindowManager.shared
        switch zone {
        case .screenEdge(let side, _):
            wm.dock(candidate.window, side: side)
        case .windowEdge(let side, let target):
            wm.dock(candidate.window, side: side, beside: target)
        case .tabGroup(let target):
            wm.group(candidate.window, with: target)
        case .desktopEdge(let side, _):
            wm.dock(candidate.window, side: side)
        case .desktopFill:
            wm.fillDesktop(with: candidate.window)
        case nil:
            // Let go in the open: the window moves to where the picture was, floating.
            if wm.isManaged(candidate.window.id) { wm.float(candidate.window, restore: false) }
            let scale: CGFloat = 0.5
            let origin = CGPoint(x: point.x - grabOffset.x / scale, y: point.y - grabOffset.y / scale)
            candidate.window.setFrame(CGRect(origin: origin, size: candidate.frame.size))
            DebugLog.write("drag placed at \(Int(origin.x)),\(Int(origin.y)) -> now \(candidate.window.frame)")
            wm.scheduleApply()
        }
        return true
    }

    // MARK: - Fallback without an event tap

    private func startMonitors() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            Task { @MainActor in self?.mouseDown(at: self!.pointer, clickCount: e.clickCount) }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in
                guard let self, let c = self.candidate else { return }
                let p = self.pointer
                if !self.takenOver, hypot(p.x - c.start.x, p.y - c.start.y) > 12 {
                    self.takenOver = true
                    WindowManager.shared.isUserDragging = true
                }
                if self.takenOver { self.updateZone(at: p, dragged: c.window) }
            }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, let c = self.candidate, self.takenOver else { self?.candidate = nil; return }
                self.highlight.hide()
                WindowManager.shared.isUserDragging = false
                let wm = WindowManager.shared
                switch self.zone {
                case .screenEdge(let side, _): wm.dock(c.window, side: side)
                case .windowEdge(let side, let target): wm.dock(c.window, side: side, beside: target)
                case .tabGroup(let target): wm.group(c.window, with: target)
                case .desktopEdge(let side, _): wm.dock(c.window, side: side)
                case .desktopFill: wm.fillDesktop(with: c.window)
                case nil: if wm.isManaged(c.window.id) { wm.float(c.window, restore: false) }
                }
                wm.scheduleApply()
                self.candidate = nil; self.takenOver = false; self.zone = nil
            }
        }
        let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in if let self { WindowManager.shared.hoverSeams(at: self.pointer) } }
        }
        monitors = [down, drag, up, moved].compactMap { $0 }
    }

    // MARK: - Zones

    private func updateZone(at point: CGPoint, dragged: AXWindow) {
        zone = zone(at: point, excluding: dragged)
        if let zone {
            highlight.show(rect: previewRect(for: zone))
        } else {
            highlight.hide()
        }
    }

    private func zone(at point: CGPoint, excluding dragged: AXWindow) -> Zone? {
        guard let screen = NSScreen.screens.first(where: { Quartz.rect(fromAppKit: $0.frame).contains(point) }) ?? NSScreen.main else { return nil }
        let visible = Quartz.visibleFrame(of: screen)
        let near: [(Side, Bool)] = [(.left, point.x - visible.minX < edgeBand), (.right, visible.maxX - point.x < edgeBand),
                                    (.top, point.y - visible.minY < edgeBand), (.bottom, visible.maxY - point.y < edgeBand)]
        for (side, isNear) in near where !isNear { armedEdges.insert(side) }
        for (side, isNear) in near where isNear && armedEdges.contains(side) { return .screenEdge(side, screen) }

        guard let target = WindowManager.shared.managedWindow(at: point, excluding: dragged.id) else {
            // Over the Desktop cell between docked windows: its edges split it, its middle fills it.
            if let d = WindowManager.shared.desktopCell(at: point), d.contains(point) {
                let dx = min(point.x - d.minX, d.maxX - point.x) / d.width
                let dy = min(point.y - d.minY, d.maxY - point.y) / d.height
                if dx < windowBand && dx <= dy { middleHover = nil; return .desktopEdge(point.x - d.minX < d.maxX - point.x ? .left : .right, d) }
                if dy < windowBand { middleHover = nil; return .desktopEdge(point.y - d.minY < d.maxY - point.y ? .top : .bottom, d) }
                let now = ProcessInfo.processInfo.systemUptime
                if let hover = middleHover, hover.id == 0 { return now - hover.since >= groupHoldSeconds ? .desktopFill(d) : nil }
                middleHover = (0, now)
                return nil
            }
            middleHover = nil
            return nil
        }
        let f = target.frame
        let dx = min(point.x - f.minX, f.maxX - point.x) / f.width
        let dy = min(point.y - f.minY, f.maxY - point.y) / f.height
        if dx < windowBand && dx <= dy {
            middleHover = nil
            return .windowEdge(point.x - f.minX < f.maxX - point.x ? .left : .right, target)
        }
        if dy < windowBand {
            middleHover = nil
            return .windowEdge(point.y - f.minY < f.maxY - point.y ? .top : .bottom, target)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let hover = middleHover, hover.id == target.id {
            return now - hover.since >= groupHoldSeconds ? .tabGroup(target) : nil
        }
        middleHover = (target.id, now)
        return nil
    }

    private func previewRect(for zone: Zone) -> CGRect {
        switch zone {
        case .screenEdge(let side, let screen):
            return half(of: Quartz.visibleFrame(of: screen), side: side, fraction: 0.4)
        case .windowEdge(let side, let target):
            return half(of: target.frame, side: side, fraction: 0.5)
        case .tabGroup(let target):
            return target.frame
        case .desktopEdge(let side, let d):
            return half(of: d, side: side, fraction: 0.5)
        case .desktopFill(let d):
            return d
        }
    }

    private func half(of r: CGRect, side: Side, fraction: CGFloat) -> CGRect {
        switch side {
        case .left: CGRect(x: r.minX, y: r.minY, width: r.width * fraction, height: r.height)
        case .right: CGRect(x: r.maxX - r.width * fraction, y: r.minY, width: r.width * fraction, height: r.height)
        case .top: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * fraction)
        case .bottom: CGRect(x: r.minX, y: r.maxY - r.height * fraction, width: r.width, height: r.height * fraction)
        }
    }
}

/// The event tap callback is a plain C function; this is how it finds the controller.
nonisolated(unsafe) var dragDockShared: DragDockController?

/// The translucent drop-target preview.
final class HighlightPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        contentView = view
    }

    func show(rect: CGRect) {
        setFrame(Quartz.appKitRect(from: rect.insetBy(dx: 6, dy: 6)), display: true)
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        if isVisible { orderOut(nil) }
    }
}
