import AppKit

/// One tree per display. `focus` is the subtree that currently fills the screen; nil means
/// the whole tree ("everything").
final class Space {
    let screen: NSScreen
    /// Always has at least the Desktop cell.
    var root: LayoutNode
    var focus: LayoutNode?
    /// Floating windows on this screen, as unit rectangles of the full Desktop (0…1 on both axes),
    /// so they scale with the Desktop cell and come back when it is the whole screen again.
    var floating: [CGWindowID: CGRect] = [:]
    /// Hidden Desktop: docked windows take the whole screen and floating windows are left alone.
    var desktopHidden = false
    /// Camera history: where the view has been (nil = everything). Back and forward walk it.
    var history: [LayoutNode?] = [nil]
    var historyIndex = 0

    init(screen: NSScreen) {
        self.screen = screen
        root = LayoutNode(desktop: ())
    }

    var visible: LayoutNode { focus ?? root }
    var hasDockedWindows: Bool { !root.windowIDs.isEmpty }
}

/// Owns the trees, the window handles and the seam overlays. Everything happens on the main thread.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var spaces: [Space] = []
    private var windows: [CGWindowID: AXWindow] = [:]
    /// Where each window was before Weaver first moved it, so floating puts it back.
    private var originalFrames: [CGWindowID: CGRect] = [:]
    private var seams: [SeamPanel] = []
    private var tiles: [CGWindowID: TilePanel] = [:]
    /// Chips for docked windows outside the camera, lined up at the bottom of the screen.
    private var parked: [CGWindowID: TilePanel] = [:]
    private var strips: [TabStripPanel] = []
    /// Which member was last brought to the front per tab group, to raise only on change.
    private var raisedMember: [ObjectIdentifier: CGWindowID] = [:]
    /// The cell each docked window was last asked to fill. Asking again for the same frame
    /// would only make an app that clamps to its minimum size resize (and notify) forever.
    private var requested: [CGWindowID: CGRect] = [:]
    private var applying = false
    private var observers: [pid_t: AXObserver] = [:]
    private var applyTimer: Timer?
    /// While the user drags a window Weaver must not snap it back into its cell.
    var isUserDragging = false
    /// Set by camera moves: the next layout pass eases windows into place instead of jumping.
    private var animateNextApply = false
    private var animation: Timer?

    var log: (String) -> Void = { NSLog("%@", $0) }

    private init() {
        rebuildSpaces()
        // Keep the floating-window bookkeeping warm so the first dock already knows everyone.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in
                let wm = WindowManager.shared
                guard !wm.isUserDragging else { return }
                for s in wm.spaces { wm.refreshFloating(in: s) }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildSpaces(); self?.apply() }
        }
    }

    private func rebuildSpaces() {
        let existing = spaces
        spaces = NSScreen.screens.map { screen in
            existing.first { $0.screen == screen } ?? Space(screen: screen)
        }
    }

    // MARK: - Queries

    private func space(for window: AXWindow) -> Space {
        let frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return spaces.first { Quartz.rect(fromAppKit: $0.screen.frame).contains(center) } ?? spaces[0]
    }

    private func space(containing id: CGWindowID) -> (Space, LayoutNode)? {
        for s in spaces {
            if let node = s.root.find(window: id) { return (s, node) }
        }
        return nil
    }

    var focusedWindow: AXWindow? { WindowList.focused() }

    // MARK: - Commands

    /// Docks the window at the outer edge of its display's tree.
    func dock(_ window: AXWindow, side: Side) {
        guard !Preferences.shared.isExcluded(pid: window.pid) else { return }
        let s = space(for: window)
        // Measure the floating windows while the Desktop cell still has its current size, so
        // they scale from where they really are once the tree changes.
        refreshFloating(in: s)
        remember(window, in: s)
        window.unminimize()
        if let existing = s.root.find(window: window.id) {
            // Already managed: move it to the edge instead of adding it twice.
            s.root = s.root.remove(existing) ?? LayoutNode(desktop: ())
            if s.focus === existing { s.focus = nil }
        }
        s.floating[window.id] = nil
        let leaf = LayoutNode(window: window.id)
        // Edge docking goes next to the Desktop cell, so the Desktop stays between the
        // docked windows; with the Desktop hidden it goes to the outside of what is visible.
        let anchor: LayoutNode = {
            if let focus = s.focus { return focus }
            if !s.desktopHidden, let desktop = s.root.desktopNode { return desktop }
            return s.root
        }()
        s.root = anchor.root.insert(leaf, side: side, of: anchor)
        log("dock \(window) \(side)")
        apply()
    }

    /// Docks the window beside another managed window.
    func dock(_ window: AXWindow, side: Side, beside target: AXWindow) {
        guard !Preferences.shared.isExcluded(pid: window.pid) else { return }
        guard let (s, targetNode) = space(containing: target.id) else { return dock(window, side: side) }
        refreshFloating(in: s)
        remember(window, in: s)
        if let existing = s.root.find(window: window.id) {
            s.root = s.root.remove(existing) ?? LayoutNode(desktop: ())
            if s.focus === existing { s.focus = nil }
        }
        s.floating[window.id] = nil
        let leaf = LayoutNode(window: window.id)
        s.root = s.root.insert(leaf, side: side, of: targetNode)
        apply()
    }

    /// `restore` puts the window back where it was before docking; false leaves it where it is now.
    /// Puts `window` into a tab group with `target` (creating the group if needed), in front.
    func group(_ window: AXWindow, with target: AXWindow) {
        guard let (s, targetNode) = space(containing: target.id) else { return }
        refreshFloating(in: s)
        remember(window, in: s)
        if let existing = s.root.find(window: window.id) {
            if existing === targetNode { return }
            if existing.isTabs { existing.removeMember(window.id) } else {
                s.root = s.root.remove(existing) ?? LayoutNode(desktop: ())
            }
            if s.focus === existing { s.focus = nil }
        }
        s.floating[window.id] = nil
        if targetNode.isTabs { targetNode.addMember(window.id) } else { targetNode.makeTabs(adding: window.id) }
        log("group \(window) with \(target)")
        apply()
    }

    func activateTab(_ node: LayoutNode, window id: CGWindowID) {
        guard node.isTabs, node.members.contains(id) else { return }
        node.activeMember = id
        apply()
    }

    func float(_ window: AXWindow, restore: Bool = true) {
        guard let (s, node) = space(containing: window.id) else { return }
        if node.isTabs {
            // Leaving a group: the others keep the cell.
            node.removeMember(window.id)
        } else {
            if let f = s.focus, node.contains(f) { s.focus = nil }
            s.root = s.root.remove(node) ?? LayoutNode(desktop: ())
        }
        tiles[window.id]?.hide()
        requested[window.id] = nil
        release(window.id, restore: restore)
        apply()
    }

    func isManaged(_ id: CGWindowID) -> Bool { space(containing: id) != nil }

    /// The docked window whose current frame contains the point.
    func managedWindow(at point: CGPoint, excluding: CGWindowID? = nil) -> AXWindow? {
        for s in spaces {
            for id in s.visible.windowIDs where id != excluding {
                if let w = windows[id], w.frame.contains(point) { return w }
            }
        }
        return nil
    }

    func floatAll() {
        for s in spaces { s.root = LayoutNode(desktop: ()); s.focus = nil }
        for id in Array(windows.keys) { release(id) }
        tiles.values.forEach { $0.hide() }
        parked.values.forEach { $0.hide() }
        requested.removeAll()
        raisedMember.removeAll()
        apply()
    }

    private func remember(_ window: AXWindow, in s: Space? = nil) {
        // The original frame is what floating should restore. A window taken from a shrunken
        // Desktop cell is remembered at full-screen scale, not at the size it was squeezed to.
        if originalFrames[window.id] == nil {
            if let s, let unit = s.floating[window.id] {
                let full = Quartz.visibleFrame(of: s.screen)
                originalFrames[window.id] = CGRect(x: full.minX + unit.minX * full.width, y: full.minY + unit.minY * full.height,
                                                   width: unit.width * full.width, height: unit.height * full.height)
            } else {
                originalFrames[window.id] = window.frame
            }
        }
        windows[window.id] = window
        observe(pid: window.pid)
    }

    /// Re-apply shortly after an app moves or resizes one of its windows itself (a dialog
    /// grew, the user hit the green button, a double-click zoomed it), so cells stay cells.
    private func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            Task { @MainActor in WindowManager.shared.scheduleApply() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    /// Coalesces bursts of notifications into one layout pass.
    func scheduleApply() {
        guard !isUserDragging else { return }
        applyTimer?.invalidate()
        applyTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            Task { @MainActor in
                guard !WindowManager.shared.isUserDragging else { return }
                WindowManager.shared.apply()
            }
        }
    }

    /// Forget a window and, unless told otherwise, put it back where the user had it.
    private func release(_ id: CGWindowID, restore: Bool = true) {
        if restore, let w = windows[id], let original = originalFrames[id], w.isAlive {
            w.setFrame(original)
            lastPlaced[id] = nil   // measured afresh as a floating window on the next pass
        }
        windows[id] = nil
        originalFrames[id] = nil
    }

    /// Zoom into the window's node (toggles back out when it is already the focus).
    func zoom(_ window: AXWindow) {
        guard let (s, node) = space(containing: window.id) else { return }
        setFocus(s.focus === node ? nil : node, in: s)
    }

    /// Every camera move goes through here so back/forward can replay it.
    private func setFocus(_ node: LayoutNode?, in s: Space, record: Bool = true) {
        s.focus = node
        animateNextApply = true
        if record {
            s.history.removeSubrange((s.historyIndex + 1)...)
            s.history.append(node)
            if s.history.count > 50 { s.history.removeFirst() }
            s.historyIndex = s.history.count - 1
        }
        apply()
        raiseVisible(in: s)
    }

    var mainSpace: Space { spaces.first { $0.screen == NSScreen.main } ?? spaces[0] }

    /// Camera to the cell next to the current one. Climbs until a split runs along the
    /// requested axis and the current branch is not already at that edge.
    func stepToNeighbour(_ side: Side) {
        let s = mainSpace
        var node: LayoutNode? = s.focus ?? focusedLeaf(in: s)
        while let current = node, let parent = current.parent {
            if parent.axis == side.axis, let i = parent.children.firstIndex(where: { $0 === current }) {
                let j = side.before ? i - 1 : i + 1
                if parent.children.indices.contains(j) {
                    setFocus(parent.children[j], in: s)
                    return
                }
            }
            node = parent
        }
    }

    /// One level in, toward the focused window (or the first child when it is elsewhere).
    func stepIn() {
        let s = mainSpace
        let from = s.focus ?? s.root
        guard !from.isLeaf, !from.children.isEmpty else { return }
        let target = focusedLeaf(in: s).flatMap { leaf in from.children.first { $0.contains(leaf) } } ?? from.children[0]
        setFocus(target, in: s)
    }

    /// The leaf holding the frontmost window, if it is docked on this screen.
    private func focusedLeaf(in s: Space) -> LayoutNode? {
        guard let w = WindowList.focused() else { return nil }
        return s.root.find(window: w.id)
    }

    // MARK: - Saved views

    private var savedViews: [Int: (space: Space, node: LayoutNode?)] = [:]
    var savedViewNumbers: [Int] { savedViews.keys.sorted() }

    func saveView(_ n: Int) {
        let s = mainSpace
        savedViews[n] = (s, s.focus)
        log("saved view \(n)")
        persist()
    }

    // MARK: - Persistence

    private var persistTimer: Timer?

    /// Writes the trees a moment after they change (called from apply).
    private func persistSoon() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            Task { @MainActor in WindowManager.shared.persist() }
        }
    }

    /// Quitting: write the arrangement as it is now, then hand the windows back.
    func persistAndFloatAll() {
        persistTimer?.invalidate()
        persist()
        floatAll()
        persistTimer?.invalidate()   // the float must not overwrite what was just saved
    }

    private func persist() {
        let records = spaces.enumerated().map { i, s in
            var views: [Int: [Int]] = [:]
            for (n, v) in savedViews where v.space === s {
                views[n] = v.node.map { Persistence.path(to: $0) } ?? []
            }
            return Persistence.SpaceRecord(screen: i, root: Persistence.record(s.root, windows: windows),
                                           desktopHidden: s.desktopHidden, savedViews: views)
        }
        Persistence.save(records)
    }

    /// Brings last session's arrangement back, matching windows that are on screen now.
    func restore() {
        let records = Persistence.load()
        guard !records.isEmpty else { return }
        var available = WindowList.onScreen().filter { !Preferences.shared.isExcluded(pid: $0.pid) }
        for r in records {
            guard spaces.indices.contains(r.screen) else { continue }
            let s = spaces[r.screen]
            var used: [CGWindowID: AXWindow] = [:]
            guard let root = Persistence.rebuild(r.root, available: &available, used: &used), !root.windowIDs.isEmpty else { continue }
            if root.desktopNode == nil {
                // Every tree keeps its Desktop cell; put one back beside the restored windows.
                s.root = root.insert(LayoutNode(desktop: ()), side: .left, of: root)
            } else {
                s.root = root
            }
            s.desktopHidden = r.desktopHidden
            for (id, w) in used {
                remember(w)
                s.floating[id] = nil
            }
            for (n, path) in r.savedViews {
                savedViews[n] = (s, path.isEmpty ? nil : Persistence.node(at: path, in: s.root))
            }
            log("restored screen \(r.screen): \(describe(s.root))")
        }
        apply()
    }

    func goToView(_ n: Int) {
        guard let saved = savedViews[n] else { return }
        // A node that has since left the tree is no use; drop the slot instead of showing nothing.
        if let node = saved.node, node.root !== saved.space.root { savedViews[n] = nil; return }
        setFocus(saved.node, in: saved.space)
    }

    func goBack() {
        let s = mainSpace
        guard s.historyIndex > 0 else { return }
        s.historyIndex -= 1
        setFocus(s.history[s.historyIndex], in: s, record: false)
    }

    func goForward() {
        let s = mainSpace
        guard s.historyIndex < s.history.count - 1 else { return }
        s.historyIndex += 1
        setFocus(s.history[s.historyIndex], in: s, record: false)
    }

    /// Bring the windows of the visible subtree in front of whatever else is on the screen.
    private func raiseVisible(in s: Space) {
        for id in s.visible.windowIDs {
            windows[id]?.raise()
        }
    }

    /// One level out: the parent of the current focus, up to the whole tree.
    func zoomOut(on screen: NSScreen? = nil) {
        let s = spaces.first { $0.screen == (screen ?? NSScreen.main) } ?? spaces[0]
        guard s.focus != nil else { return }
        setFocus(s.focus?.parent, in: s)
    }

    func toggleDesktop(on screen: NSScreen? = nil) {
        let s = spaces.first { $0.screen == (screen ?? NSScreen.main) } ?? spaces[0]
        s.desktopHidden.toggle()
        if !s.desktopHidden, let desktop = s.root.desktopNode, let parent = desktop.parent,
           let d = parent.children.firstIndex(where: { $0 === desktop }) {
            parent.reviveShare(at: d)
        }
        apply()
    }

    func showEverything() {
        for s in spaces where s.focus != nil { setFocus(nil, in: s) }
        apply()
    }

    // MARK: - Layout

    func apply() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        pruneDeadWindows()
        // A hidden Desktop only makes sense between docked windows; with none left, show it.
        for s in spaces where s.desktopHidden && !s.hasDockedWindows { s.desktopHidden = false }
        LayoutEngine.gap = Preferences.shared.gap

        var allSeams: [(Seam, Space)] = []
        var allStrips: [TabStrip] = []
        var laidOut = Set<CGWindowID>()
        var resizeAdopted = false
        let animate = animateNextApply
        animateNextApply = false
        var animations: [(AXWindow, CGRect, CGRect)] = []
        for s in spaces {
            refreshFloating(in: s)
            let full = Quartz.visibleFrame(of: s.screen)
            let hideDesktop = s.desktopHidden || (s.floating.isEmpty && s.hasDockedWindows)
            let layout = LayoutEngine.layout(s.visible, in: full, hideDesktop: hideDesktop)
            for (id, frame) in layout.frames {
                guard let w = windows[id] else { continue }
                let before = w.frame
                if animate, requested[id] != frame, before != .zero {
                    animations.append((w, before, frame))
                    requested[id] = frame
                    updateTile(for: w, cell: frame, actual: frame)
                    continue
                }
                let moved = abs(before.minX - frame.minX) > 3 || abs(before.minY - frame.minY) > 3
                // The user is resizing the window by its own edge: move the seam instead of
                // snapping the window back, so the neighbours give way like in a real tiling.
                if requested[id] == frame, NSEvent.pressedMouseButtons & 1 != 0,
                   let node = s.root.find(window: id), adoptUserResize(node, cell: frame, actual: before) {
                    resizeAdopted = true
                    continue
                }
                if requested[id] != frame || moved {
                    w.setFrame(frame)
                    requested[id] = frame
                    // The app may clamp a moment later; the AX observer brings us back here.
                    updateTile(for: w, cell: frame, actual: w.frame)
                } else {
                    updateTile(for: w, cell: frame, actual: before)
                }
            }
            if !s.desktopHidden { placeFloating(in: s, desktopRect: layout.desktopRect, full: full) }
            laidOut.formUnion(layout.frames.keys)
            allSeams.append(contentsOf: layout.seams.map { ($0, s) })
            allStrips.append(contentsOf: layout.tabStrips)
        }
        // Only after every screen is placed: a tile belongs to one screen's layout.
        for id in tiles.keys where !laidOut.contains(id) { tiles[id]?.hide() }
        updateParked()
        updateSeams(allSeams)
        updateStrips(allStrips)
        if resizeAdopted {
            // Ratios changed under us: lay out again so the neighbours follow right away.
            applying = false
            apply()
        }
        if !animations.isEmpty { run(animations) }
        persistSoon()
    }

    /// Eases windows from where they are to their cells over a few frames: the camera feel.
    /// Apps that clamp their size simply stop early; the final pass sets the exact frame.
    private func run(_ moves: [(AXWindow, CGRect, CGRect)]) {
        animation?.invalidate()
        let steps = 8
        var step = 0
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            step += 1
            let t = CGFloat(step) / CGFloat(steps)
            let eased = 1 - pow(1 - t, 3)
            for (w, from, to) in moves {
                let r = CGRect(x: from.minX + (to.minX - from.minX) * eased,
                               y: from.minY + (to.minY - from.minY) * eased,
                               width: from.width + (to.width - from.width) * eased,
                               height: from.height + (to.height - from.height) * eased)
                w.setFrame(step == steps ? to : r)
            }
            if step >= steps {
                timer.invalidate()
                Task { @MainActor in self?.scheduleApply() }
            }
        }
    }

    /// Translate a window the user resized by hand into a seam move on its parent split.
    /// Returns false when the node has no split along the changed axis.
    private func adoptUserResize(_ node: LayoutNode, cell: CGRect, actual: CGRect) -> Bool {
        let dw = actual.width - cell.width, dh = actual.height - cell.height
        guard abs(dw) > 2 || abs(dh) > 2 else { return false }
        var changed = false
        if abs(dw) > 2, let parent = node.parent, parent.axis == .horizontal,
           let index = parent.children.firstIndex(where: { $0 === node }) {
            let length = cell.width / max(parent.ratios[index], 0.01)
            if abs(actual.minX - cell.minX) > 2, index > 0 {
                parent.moveSeam(at: index - 1, by: (actual.minX - cell.minX) / length)     // left edge
                changed = true
            } else if index < parent.children.count - 1 {
                parent.moveSeam(at: index, by: dw / length)                                // right edge
                changed = true
            }
        }
        if abs(dh) > 2, let parent = node.parent, parent.axis == .vertical,
           let index = parent.children.firstIndex(where: { $0 === node }) {
            let length = cell.height / max(parent.ratios[index], 0.01)
            if abs(actual.minY - cell.minY) > 2, index > 0 {
                parent.moveSeam(at: index - 1, by: (actual.minY - cell.minY) / length)     // top edge
                changed = true
            } else if index < parent.children.count - 1 {
                parent.moveSeam(at: index, by: dh / length)                                // bottom edge
                changed = true
            }
        }
        return changed
    }

    /// Windows docked on a screen but outside its camera get a chip at the bottom edge;
    /// one click brings the camera to them. With the camera on everything there are none.
    private func updateParked() {
        var wanted: [CGWindowID: (Space, CGRect)] = [:]
        for s in spaces {
            guard s.focus != nil else { continue }
            let visible = Set(s.visible.windowIDs)
            let outside = s.root.windowIDs.filter { !visible.contains($0) }
            guard !outside.isEmpty else { continue }
            let full = Quartz.visibleFrame(of: s.screen)
            let w: CGFloat = 150, h: CGFloat = 60, gapX: CGFloat = 8
            let total = CGFloat(outside.count) * w + CGFloat(outside.count - 1) * gapX
            var x = full.midX - total / 2
            for id in outside {
                wanted[id] = (s, CGRect(x: x, y: full.maxY - h - 8, width: w, height: h))
                x += w + gapX
            }
        }
        for (id, panel) in parked where wanted[id] == nil { panel.hide() }
        for (id, (_, rect)) in wanted {
            guard let w = windows[id] else { continue }
            let panel = parked[id] ?? TilePanel()
            parked[id] = panel
            panel.show(rect: rect, window: w, compact: true) { [weak self] in self?.zoom(w) }
        }
    }

    private func updateStrips(_ list: [TabStrip]) {
        while strips.count > list.count { strips.removeLast().orderOut(nil) }
        for (i, strip) in list.enumerated() {
            let node = strip.node
            let members = node.members.compactMap { windows[$0] }
            let panel = i < strips.count ? strips[i] : { let p = TabStripPanel(); strips.append(p); return p }()
            panel.update(strip: strip, windows: members, active: node.activeMember,
                         onSelect: { [weak self] id in self?.activateTab(node, window: id) },
                         onClose: { [weak self] id in
                             guard let self, let w = self.windows[id] else { return }
                             self.float(w, restore: false)
                         })
            // Bring the active member in front of its siblings, once per change.
            if let active = node.activeMember, raisedMember[ObjectIdentifier(node)] != active {
                windows[active]?.raise()
                raisedMember[ObjectIdentifier(node)] = active
            }
        }
    }

    /// The Desktop cell: every floating window keeps its place and size relative to the full
    /// screen, and is drawn scaled into whatever rectangle the cell currently has.
    private func placeFloating(in s: Space, desktopRect: CGRect?, full: CGRect) {
        let target = desktopRect ?? full
        for (id, unit) in s.floating {
            guard let w = windows[id] else { continue }
            let frame = CGRect(x: target.minX + unit.minX * target.width,
                               y: target.minY + unit.minY * target.height,
                               width: unit.width * target.width,
                               height: unit.height * target.height)
            if !approximatelyEqual(w.frame, frame) {
                w.setFrame(frame)
                lastPlaced[id] = w.frame   // what the app accepted, which may differ from what we asked
            }
        }
    }

    private var lastPlaced: [CGWindowID: CGRect] = [:]

    /// Adopt new floating windows and forget closed ones. A window the user moved since we placed
    /// it gets a fresh unit rectangle, measured against the Desktop cell it is currently inside.
    private func refreshFloating(in s: Space) {
        let full = Quartz.visibleFrame(of: s.screen)
        let screenRect = Quartz.rect(fromAppKit: s.screen.frame)
        let docked = Set(s.root.windowIDs)
        let onScreen = WindowList.onScreen().filter { screenRect.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let desktopRect = currentDesktopRect(in: s) ?? full
        var seen = Set<CGWindowID>()
        for w in onScreen where !docked.contains(w.id) && !w.isMinimized && !Preferences.shared.isExcluded(pid: w.pid) {
            seen.insert(w.id)
            windows[w.id] = w
            let frame = w.frame
            // Never placed by us, or moved by the user since: measure it against the Desktop
            // cell it currently sits in. Otherwise it is where we left it and the unit rect holds.
            let placed = lastPlaced[w.id]
            if placed == nil || !approximatelyEqual(placed!, frame) {
                let base = desktopRect
                s.floating[w.id] = CGRect(x: (frame.minX - base.minX) / base.width,
                                          y: (frame.minY - base.minY) / base.height,
                                          width: frame.width / base.width,
                                          height: frame.height / base.height)
                // From now on this frame counts as "where we left it", so the unit rect is
                // only re-measured when the window actually moves.
                lastPlaced[w.id] = frame
            }
            observe(pid: w.pid)
        }
        for id in Array(s.floating.keys) where !seen.contains(id) {
            s.floating[id] = nil
            lastPlaced[id] = nil
            if space(containing: id) == nil { windows[id] = nil }
        }
    }

    /// The Desktop cell's rectangle on the screen under `point`, when docked windows share
    /// that screen (otherwise the whole screen is the Desktop and the edges handle drops).
    func desktopCell(at point: CGPoint) -> CGRect? {
        guard let s = spaces.first(where: { Quartz.rect(fromAppKit: $0.screen.frame).contains(point) }),
              s.hasDockedWindows, !s.desktopHidden else { return nil }
        return currentDesktopRect(in: s)
    }

    /// Dock `window` where the Desktop cell is and hide the Desktop: the window takes the middle.
    func fillDesktop(with window: AXWindow) {
        let s = space(for: window)
        dock(window, side: .left)          // lands beside the Desktop cell
        if let desktop = s.root.desktopNode, let parent = desktop.parent,
           let leaf = s.root.find(window: window.id), leaf.parent === parent,
           let d = parent.children.firstIndex(where: { $0 === desktop }),
           let w = parent.children.firstIndex(where: { $0 === leaf }) {
            parent.transferShare(from: d, to: w)   // the window gets the Desktop's whole width
        }
        s.desktopHidden = true
        apply()
    }

    private func currentDesktopRect(in s: Space) -> CGRect? {
        let full = Quartz.visibleFrame(of: s.screen)
        return LayoutEngine.layout(s.visible, in: full, hideDesktop: false).desktopRect
    }

    private func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 3 && abs(a.minY - b.minY) < 3 && abs(a.width - b.width) < 3 && abs(a.height - b.height) < 3
    }

    /// Apps clamp to a minimum size; when the cell is smaller than what the app accepted,
    /// cover the cell with a tile so the overflow does not look like a bug.
    private func updateTile(for w: AXWindow, cell: CGRect, actual: CGRect) {
        let squeezed = actual.width > cell.width + 6 || actual.height > cell.height + 6
        if squeezed {
            let tile = tiles[w.id] ?? TilePanel()
            tiles[w.id] = tile
            tile.show(rect: cell, window: w) { [weak self] in self?.zoom(w) }
        } else {
            tiles[w.id]?.hide()
        }
    }

    /// Lights up the seam under the pointer (Quartz point).
    func hoverSeams(at point: CGPoint) {
        let appKit = NSPoint(x: point.x, y: Quartz.primaryHeight - point.y)
        for panel in seams { panel.setHovered(panel.frame.contains(appKit)) }
    }

    private func updateSeams(_ list: [(Seam, Space)]) {
        while seams.count > list.count { seams.removeLast().orderOut(nil) }
        for (i, (seam, _)) in list.enumerated() {
            let handler: (CGFloat) -> Void = { [weak self] fraction in
                seam.split.moveSeam(at: seam.index, by: fraction)
                self?.apply()
            }
            if i < seams.count {
                seams[i].update(seam: seam, onDrag: handler)
            } else {
                seams.append(SeamPanel(seam: seam, onDrag: handler))
            }
        }
    }

    private func pruneDeadWindows() {
        for (id, w) in windows where !w.isAlive || w.isMinimized {
            if let (s, node) = space(containing: id) {
                log("prune \(w) alive=\(w.isAlive) minimized=\(w.isMinimized)")
                if node.isTabs {
                    node.removeMember(id)
                } else {
                    if let f = s.focus, node.contains(f) { s.focus = nil }
                    s.root = s.root.remove(node) ?? LayoutNode(desktop: ())
                }
            }
            if !w.isAlive { windows[id] = nil; originalFrames[id] = nil; tiles[id]?.hide(); tiles[id] = nil }
        }
    }

    // MARK: - Debug

    func describe() -> String {
        let tileInfo = tiles.map { id, t in "tile#\(id) visible=\(t.isVisible) frame=\(Int(t.frame.minX)),\(Int(t.frame.minY)) \(Int(t.frame.width))x\(Int(t.frame.height)) level=\(t.level.rawValue)" }.joined(separator: "\n")
        return tileInfo + "\n" + spaces.enumerated().map { i, s in
            "screen \(i): " + describe(s.root) + " floating=\(s.floating.count)" + (s.focus != nil ? " [zoomed]" : "") + (s.desktopHidden ? " [desktop hidden]" : "")
        }.joined(separator: "\n")
    }

    private func describe(_ node: LayoutNode) -> String {
        if node.isDesktop { return "Desktop" }
        if node.isTabs { return "T[" + node.members.map { id in windows[id].map { "\($0.appName):\($0.title.prefix(10))" } ?? "#\(id)" }.joined(separator: ",") + "]" }
        if let id = node.windowID { return windows[id].map { "\($0.appName):\($0.title.prefix(12))" } ?? "#\(id)" }
        let inner = node.children.enumerated().map { i, c in "\(describe(c))@\(String(format: "%.2f", node.ratios[i]))" }
        return (node.axis == .horizontal ? "H(" : "V(") + inner.joined(separator: " | ") + ")"
    }
}
