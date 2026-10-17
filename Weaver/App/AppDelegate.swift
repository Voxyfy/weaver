import AppKit
import Sparkle

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKeys = HotKeyCenter()
    private let dragDock = DragDockController()
    /// Sparkle checks the appcast daily; it only starts when the build carries a public key.
    private let updater = SPUStandardUpdaterController(startingUpdater: AppDelegate.hasUpdateKey,
                                                        updaterDelegate: nil, userDriverDelegate: nil)

    static var hasUpdateKey: Bool {
        !((Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) ?? "").isEmpty
    }
    private var logLines: [String] = []

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXPermission.requestIfNeeded()
        WindowList.startTrackingFrontmost()
        WindowManager.shared.log = { [weak self] line in
            self?.logLines.append(line)
            NSLog("%@", line)
            DebugLog.write(line)
        }
        setupStatusItem()
        setupHotKeys()
        dragDock.start()
        // Give the other apps a moment to be listed, then bring last session's layout back.
        if AXPermission.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WindowManager.shared.restore() }
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:_:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// Quitting hands every window back where it was, so Weaver never leaves a mess behind.
    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.persistAndFloatAll()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarPill.width)
        let pill = MenuBarPill(frame: NSRect(x: 0, y: 0, width: MenuBarPill.width, height: 22))
        pill.onBack = { WindowManager.shared.goBack() }
        pill.onForward = { WindowManager.shared.goForward() }
        pill.onDesktop = { WindowManager.shared.toggleDesktop() }
        pill.onEverything = { WindowManager.shared.showEverything() }
        pill.onMenu = { [weak self] view in
            guard let self, let menu = self.statusMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
        statusItem.button?.addSubview(pill)
        statusItem.button?.toolTip = "Weaver"
        let menu = NSMenu()
        menu.addItem(withTitle: "Dock Focused Window Left  ⌃⌥⌘←", action: #selector(dockLeft), keyEquivalent: "")
        menu.addItem(withTitle: "Dock Focused Window Right  ⌃⌥⌘→", action: #selector(dockRight), keyEquivalent: "")
        menu.addItem(withTitle: "Dock Focused Window Top  ⌃⌥⌘↑", action: #selector(dockTop), keyEquivalent: "")
        menu.addItem(withTitle: "Dock Focused Window Bottom  ⌃⌥⌘↓", action: #selector(dockBottom), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Neighbour Left / Right  ⌃⌥← →", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Neighbour Above / Below  ⌃⌥⇧↑ ↓", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Step Out / In  ⌃⌥↑ ↓", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Save View  ⌃⌥⇧1–9 · Go to View  ⌃⌥1–9", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom Focused Window  ⌃⌥↩", action: #selector(zoomFocused), keyEquivalent: "")
        menu.addItem(withTitle: "Show Everything  ⌃⌥Space", action: #selector(showEverything), keyEquivalent: "")
        menu.addItem(withTitle: "Hide/Show Desktop  ⌃⌥D", action: #selector(toggleDesktop), keyEquivalent: "")
        menu.addItem(withTitle: "Back  ⌃⌥[", action: #selector(goBack), keyEquivalent: "")
        menu.addItem(withTitle: "Forward  ⌃⌥]", action: #selector(goForward), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Float Focused Window  ⌃⌥F", action: #selector(floatFocused), keyEquivalent: "")
        menu.addItem(withTitle: "Float All Windows  ⌃⌥⇧F", action: #selector(floatAll), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Don't Arrange This App", action: #selector(toggleExcludeFrontmost), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        let ax = menu.addItem(withTitle: AXPermission.isTrusted ? "Accessibility: allowed" : "Accessibility: not allowed (click to open)",
                              action: #selector(openAccessibility), keyEquivalent: "")
        ax.isEnabled = true
        menu.addItem(withTitle: "Quit Weaver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        statusMenu = menu   // shown from the pill's menu button, not on every click
    }

    private var statusMenu: NSMenu?

    /// Binds every action to its current shortcut; called again whenever one changes.
    func setupHotKeys() {
        hotKeys.unregisterAll()
        let wm = WindowManager.shared
        for action in ShortcutAction.allCases {
            let s = ShortcutStore.shortcut(for: action)
            let handler: () -> Void
            switch action {
            case .neighbourLeft: handler = { wm.stepToNeighbour(.left) }
            case .neighbourRight: handler = { wm.stepToNeighbour(.right) }
            case .neighbourUp: handler = { wm.stepToNeighbour(.top) }
            case .neighbourDown: handler = { wm.stepToNeighbour(.bottom) }
            case .stepOut: handler = { wm.zoomOut() }
            case .stepIn: handler = { wm.stepIn() }
            case .zoomFocused: handler = { [weak self] in self?.zoomFocused() }
            case .everything: handler = { wm.showEverything() }
            case .back: handler = { wm.goBack() }
            case .forward: handler = { wm.goForward() }
            case .toggleDesktop: handler = { wm.toggleDesktop() }
            case .dockLeft: handler = { [weak self] in self?.dockLeft() }
            case .dockRight: handler = { [weak self] in self?.dockRight() }
            case .dockTop: handler = { [weak self] in self?.dockTop() }
            case .dockBottom: handler = { [weak self] in self?.dockBottom() }
            case .floatFocused: handler = { [weak self] in self?.floatFocused() }
            case .floatAll: handler = { [weak self] in self?.floatAll() }
            }
            hotKeys.register(.init(code: s.code, modifiers: s.modifiers), handler: handler)
        }
        // Saved views keep fixed keys: ⌃⌥⇧digit saves, ⌃⌥digit goes.
        let co = HotKeyCenter.Key.control | HotKeyCenter.Key.option
        for (i, code) in KeyCode.digits.enumerated() {
            hotKeys.register(.init(code: code, modifiers: co | HotKeyCenter.Key.shift)) { wm.saveView(i + 1) }
            hotKeys.register(.init(code: code, modifiers: co)) { wm.goToView(i + 1) }
        }
        hotKeys.register(.init(code: KeyCode.escape, modifiers: co)) { wm.zoomOut() }
    }

    // MARK: - Actions

    @objc private func dockLeft() { dockFocused(.left) }
    @objc private func dockRight() { dockFocused(.right) }
    @objc private func dockTop() { dockFocused(.top) }
    @objc private func dockBottom() { dockFocused(.bottom) }

    private func dockFocused(_ side: Side) {
        guard let w = WindowManager.shared.focusedWindow else { return }
        WindowManager.shared.dock(w, side: side)
    }

    @objc private func zoomFocused() {
        guard let w = WindowManager.shared.focusedWindow else { return }
        WindowManager.shared.zoom(w)
    }

    @objc private func showEverything() { WindowManager.shared.showEverything() }
    @objc private func toggleDesktop() { WindowManager.shared.toggleDesktop() }
    @objc private func goBack() { WindowManager.shared.goBack() }
    @objc private func goForward() { WindowManager.shared.goForward() }

    @objc private func floatFocused() {
        guard let w = WindowManager.shared.focusedWindow else { return }
        WindowManager.shared.float(w)
    }

    @objc private func floatAll() { WindowManager.shared.floatAll() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func checkForUpdates() { updater.updater.checkForUpdates() }

    /// The app the user was just using (not Weaver) gets added to, or removed from, the leave-alone list.
    @objc private func toggleExcludeFrontmost() {
        guard let app = WindowList.lastUserApp, let id = app.bundleIdentifier else { return }
        Preferences.shared.toggleExcluded(bundleID: id)
        if Preferences.shared.excludedApps.contains(id) {
            for w in WindowList.windows(ofApp: app.processIdentifier) where WindowManager.shared.isManaged(w.id) {
                WindowManager.shared.float(w)
            }
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - URL commands (weaver://…), also handy for scripted tests

    @objc private func handleURL(_ event: NSAppleEventDescriptor, _ reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        let params = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let wm = WindowManager.shared
        // Optional pid: act on that app's focused window instead of the frontmost app's.
        let target: AXWindow? = {
            if let pidText = params["pid"], let pid = pid_t(pidText) {
                return WindowList.windows(ofApp: pid).first { $0.isStandard && !$0.isMinimized }
            }
            return wm.focusedWindow
        }()
        switch url.host {
        case "dock":
            let side: Side = switch params["side"] { case "right": .right; case "top": .top; case "bottom": .bottom; default: .left }
            if let target { wm.dock(target, side: side) }
        case "zoom": if let target { wm.zoom(target) }
        case "zoom-out": wm.zoomOut()
        case "everything": wm.showEverything()
        case "desktop": wm.toggleDesktop()
        case "back": wm.goBack()
        case "neighbour":
            let side: Side = switch params["dir"] { case "right": .right; case "up": .top; case "down": .bottom; default: .left }
            wm.stepToNeighbour(side)
        case "step-in": wm.stepIn()
        case "settings": SettingsWindowController.shared.show()
        case "save-view": if let n = params["n"].flatMap(Int.init) { wm.saveView(n) }
        case "view": if let n = params["n"].flatMap(Int.init) { wm.goToView(n) }
        case "forward": wm.goForward()
        case "float": if let target { wm.float(target) }
        case "float-all": wm.floatAll()
        case "dump":
            let front = NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?") pid \($0.processIdentifier)" } ?? "none"
            let text = "trusted: \(AXPermission.isTrusted)\nfrontmost: \(front)\nfocused: \(wm.focusedWindow.map { "\($0)" } ?? "nil")\n"
                + "onScreen: \(WindowList.onScreen().prefix(6).map { "\($0)" }.joined(separator: ", "))\n"
                + wm.describe()
            try? text.write(toFile: NSTemporaryDirectory() + "weaver-dump.txt", atomically: true, encoding: .utf8)
            NSLog("%@", text)
        default: break
        }
    }
}


/// Plain-text log at $TMPDIR/weaver.log; easier to read than the unified log while developing.
enum DebugLog {
    static func write(_ line: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("weaver.log")
        let text = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: url) }
    }
}
