import AppKit
import Carbon

/// Global shortcuts through Carbon's RegisterEventHotKey: works without key logging and
/// does not need the Input Monitoring permission.
final class HotKeyCenter {
    struct Key {
        let code: UInt32
        let modifiers: UInt32   // Carbon modifier mask

        static let control = UInt32(controlKey), option = UInt32(optionKey), shift = UInt32(shiftKey), command = UInt32(cmdKey)
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, selfPointer, &eventHandler)
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        handlers.removeAll()
    }

    func register(_ key: Key, handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5756_5652), id: id) // "WVVR"
        RegisterEventHotKey(key.code, key.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

/// Virtual key codes for the shortcuts Weaver ships with.
enum KeyCode {
    static let leftArrow: UInt32 = 123, rightArrow: UInt32 = 124, downArrow: UInt32 = 125, upArrow: UInt32 = 126
    static let returnKey: UInt32 = 36, space: UInt32 = 49, f: UInt32 = 3, escape: UInt32 = 53, d: UInt32 = 2, leftBracket: UInt32 = 33, rightBracket: UInt32 = 30
    /// Number row 1–9.
    static let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}
