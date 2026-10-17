import AppKit
import Carbon

/// Everything a key combination can do in Weaver, with its default keys.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case neighbourLeft, neighbourRight, neighbourUp, neighbourDown
    case stepOut, stepIn, zoomFocused, everything, back, forward, toggleDesktop
    case dockLeft, dockRight, dockTop, dockBottom, floatFocused, floatAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neighbourLeft: "Neighbour to the left"
        case .neighbourRight: "Neighbour to the right"
        case .neighbourUp: "Neighbour above"
        case .neighbourDown: "Neighbour below"
        case .stepOut: "Step out a level"
        case .stepIn: "Step in a level"
        case .zoomFocused: "Frame the focused window"
        case .everything: "Show everything"
        case .back: "Back"
        case .forward: "Forward"
        case .toggleDesktop: "Hide or show the Desktop"
        case .dockLeft: "Dock focused window left"
        case .dockRight: "Dock focused window right"
        case .dockTop: "Dock focused window top"
        case .dockBottom: "Dock focused window bottom"
        case .floatFocused: "Float focused window"
        case .floatAll: "Float all windows"
        }
    }

    var defaultShortcut: Shortcut {
        let co = Shortcut.control | Shortcut.option
        switch self {
        case .neighbourLeft: return Shortcut(code: KeyCode.leftArrow, modifiers: co)
        case .neighbourRight: return Shortcut(code: KeyCode.rightArrow, modifiers: co)
        case .neighbourUp: return Shortcut(code: KeyCode.upArrow, modifiers: co | Shortcut.shift)
        case .neighbourDown: return Shortcut(code: KeyCode.downArrow, modifiers: co | Shortcut.shift)
        case .stepOut: return Shortcut(code: KeyCode.upArrow, modifiers: co)
        case .stepIn: return Shortcut(code: KeyCode.downArrow, modifiers: co)
        case .zoomFocused: return Shortcut(code: KeyCode.returnKey, modifiers: co)
        case .everything: return Shortcut(code: KeyCode.space, modifiers: co)
        case .back: return Shortcut(code: KeyCode.leftBracket, modifiers: co)
        case .forward: return Shortcut(code: KeyCode.rightBracket, modifiers: co)
        case .toggleDesktop: return Shortcut(code: KeyCode.d, modifiers: co)
        case .dockLeft: return Shortcut(code: KeyCode.leftArrow, modifiers: co | Shortcut.command)
        case .dockRight: return Shortcut(code: KeyCode.rightArrow, modifiers: co | Shortcut.command)
        case .dockTop: return Shortcut(code: KeyCode.upArrow, modifiers: co | Shortcut.command)
        case .dockBottom: return Shortcut(code: KeyCode.downArrow, modifiers: co | Shortcut.command)
        case .floatFocused: return Shortcut(code: KeyCode.f, modifiers: co)
        case .floatAll: return Shortcut(code: KeyCode.f, modifiers: co | Shortcut.shift)
        }
    }
}

/// A key code plus Carbon modifier mask, as RegisterEventHotKey wants it.
struct Shortcut: Codable, Equatable {
    var code: UInt32
    var modifiers: UInt32

    static let control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey), command = UInt32(cmdKey)

    init(code: UInt32, modifiers: UInt32) {
        self.code = code
        self.modifiers = modifiers
    }

    /// From an AppKit key event, for the recorder.
    init?(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= Shortcut.control }
        if event.modifierFlags.contains(.option) { mods |= Shortcut.option }
        if event.modifierFlags.contains(.shift) { mods |= Shortcut.shift }
        if event.modifierFlags.contains(.command) { mods |= Shortcut.command }
        guard mods != 0 else { return nil }   // a bare key would shadow typing everywhere
        self.init(code: UInt32(event.keyCode), modifiers: mods)
    }

    var display: String {
        var s = ""
        if modifiers & Shortcut.control != 0 { s += "⌃" }
        if modifiers & Shortcut.option != 0 { s += "⌥" }
        if modifiers & Shortcut.shift != 0 { s += "⇧" }
        if modifiers & Shortcut.command != 0 { s += "⌘" }
        return s + Shortcut.keyName(code)
    }

    static func keyName(_ code: UInt32) -> String {
        switch code {
        case KeyCode.leftArrow: return "←"
        case KeyCode.rightArrow: return "→"
        case KeyCode.upArrow: return "↑"
        case KeyCode.downArrow: return "↓"
        case KeyCode.returnKey: return "↩"
        case KeyCode.space: return "Space"
        case KeyCode.escape: return "Esc"
        case 51: return "⌫"
        case 48: return "⇥"
        default: break
        }
        // Letters, digits and punctuation: ask the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "key \(code)" }
        let layout = unsafeBitCast(CFDataGetBytePtr(unsafeBitCast(data, to: CFData.self)), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                 UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        guard err == noErr, length > 0 else { return "key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Where the user's overrides live. Missing entries mean the default.
@MainActor
enum ShortcutStore {
    private static let key = "shortcuts"

    static func shortcut(for action: ShortcutAction) -> Shortcut {
        overrides()[action.rawValue] ?? action.defaultShortcut
    }

    static func set(_ shortcut: Shortcut?, for action: ShortcutAction) {
        var all = overrides()
        all[action.rawValue] = shortcut
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }

    static func resetAll() { UserDefaults.standard.removeObject(forKey: key) }

    private static func overrides() -> [String: Shortcut] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let dict = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return [:] }
        return dict
    }
}
