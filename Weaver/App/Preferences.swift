import AppKit
import ServiceManagement

/// User settings, backed by UserDefaults. Read from anywhere, changed from the Settings window.
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    /// Space between docked windows, in points.
    var gap: CGFloat {
        get { CGFloat(defaults.object(forKey: "gap") as? Double ?? 8) }
        set { defaults.set(Double(newValue), forKey: "gap"); WindowManager.shared.apply() }
    }

    /// How close to a screen edge (points) a dragged window must come to dock there.
    var edgeBand: CGFloat {
        get { CGFloat(defaults.object(forKey: "edgeBand") as? Double ?? 48) }
        set { defaults.set(Double(newValue), forKey: "edgeBand") }
    }

    /// Seconds to hold a window over another's middle before it becomes a tab group.
    var groupHold: Double {
        get { defaults.object(forKey: "groupHold") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "groupHold") }
    }

    /// Bundle identifiers of apps Weaver leaves alone: never docked, never scaled.
    var excludedApps: [String] {
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(newValue, forKey: "excludedApps"); WindowManager.shared.apply() }
    }

    func isExcluded(pid: pid_t) -> Bool {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return excludedApps.contains(id)
    }

    func toggleExcluded(bundleID: String) {
        var list = excludedApps
        if let i = list.firstIndex(of: bundleID) { list.remove(at: i) } else { list.append(bundleID) }
        excludedApps = list
    }

    /// Login item through SMAppService; macOS shows it under General → Login Items.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("launch at login: %@", error.localizedDescription)
            }
        }
    }
}
