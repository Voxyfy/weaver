import AppKit
import SwiftUI

/// The Settings window: a SwiftUI form in a plain AppKit window, shown from the menu.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Weaver Settings"
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 520, height: 720))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A menu bar app is not active; activate so the window comes to the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @State private var gap: Double = Double(Preferences.shared.gap)
    @State private var edgeBand: Double = Double(Preferences.shared.edgeBand)
    @State private var groupHold: Double = Preferences.shared.groupHold
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var excluded = Preferences.shared.excludedApps
    @State private var pickingApp = false

    var body: some View {
        Form {
            Section("Windows") {
                HStack {
                    Slider(value: $gap, in: 0...24, step: 1) { Text("Space between windows") }
                    Text("\(Int(gap)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .onChange(of: gap) { _, v in Preferences.shared.gap = CGFloat(v) }
                HStack {
                    Slider(value: $edgeBand, in: 16...120, step: 4) { Text("Screen edge zone") }
                    Text("\(Int(edgeBand)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .onChange(of: edgeBand) { _, v in Preferences.shared.edgeBand = CGFloat(v) }
                HStack {
                    Slider(value: $groupHold, in: 0.2...1.5, step: 0.1) { Text("Hold to make a tab group") }
                    Text(String(format: "%.1f s", groupHold)).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .onChange(of: groupHold) { _, v in Preferences.shared.groupHold = v }
            }
            Section("Startup") {
                Toggle("Open Weaver at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in Preferences.shared.launchAtLogin = v }
            }
            Section {
                List {
                    ForEach(excluded, id: \.self) { id in
                        HStack {
                            AppRow(bundleID: id)
                            Spacer()
                            Button { remove(id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 120)
                HStack {
                    Menu("Add running app…") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") { add(app.bundleIdentifier!) }
                        }
                    }
                    .frame(width: 180)
                    Spacer()
                }
            } header: {
                Text("Leave these apps alone")
            } footer: {
                Text("Their windows float freely and are never docked or scaled.")
            }
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(action: action)
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        ShortcutStore.resetAll()
                        (NSApp.delegate as? AppDelegate)?.setupHotKeys()
                        NotificationCenter.default.post(name: .weaverShortcutsChanged, object: nil)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Click one, then press the keys you want (with ⌃, ⌥, ⇧ or ⌘). Esc cancels. Saved views keep ⌃⌥⇧1–9 and ⌃⌥1–9.")
            }
            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(AXPermission.isTrusted ? "Allowed" : "Not allowed").foregroundStyle(AXPermission.isTrusted ? .green : .red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !excluded.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func add(_ id: String) {
        excluded.append(id)
        Preferences.shared.excludedApps = excluded
    }

    private func remove(_ id: String) {
        excluded.removeAll { $0 == id }
        Preferences.shared.excludedApps = excluded
    }
}

struct AppRow: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Text(bundleID)
            }
        }
    }
}


extension Notification.Name {
    static let weaverShortcutsChanged = Notification.Name("weaverShortcutsChanged")
}

/// A button showing the current keys; click it and the next key press becomes the shortcut.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @State private var recording = false
    @State private var display = ""
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : display) {
            recording ? stop() : start()
        }
        .frame(minWidth: 110)
        .foregroundStyle(recording ? Color.accentColor : .primary)
        .onAppear { display = ShortcutStore.shortcut(for: action).display }
        .onReceive(NotificationCenter.default.publisher(for: .weaverShortcutsChanged)) { _ in
            display = ShortcutStore.shortcut(for: action).display
        }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == KeyCode.escape { stop(); return nil }
            if let s = Shortcut(event: event) {
                ShortcutStore.set(s, for: action)
                display = s.display
                (NSApp.delegate as? AppDelegate)?.setupHotKeys()
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
