import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon `RegisterEventHotKey`. Unlike `NSEvent` global monitors, this
/// needs no Accessibility permission and works while any app (including full-screen) is frontmost.
final class HotkeyManager {
    struct Hotkey {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let display: String
        let action: () -> Void
    }

    static let shared = HotkeyManager()
    private(set) var hotkeys: [UInt32: Hotkey] = [:]
    private(set) var failed: [String] = []
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    func register(_ keyCode: Int, _ modifiers: Int, display: String, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(hotkeys.count + 1)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5650_5254) /* 'VPRT' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            hotkeys[id] = Hotkey(id: id, keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), display: display, action: action)
        } else {
            failed.append(display) // Another app already owns this combination.
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if let hk = HotkeyManager.shared.hotkeys[hkID.id] {
                DispatchQueue.main.async { hk.action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum Keys {
    static let ctrlOpt = controlKey | optionKey
    static let space = kVK_Space, c = kVK_ANSI_C, r = kVK_ANSI_R, h = kVK_ANSI_H, o = kVK_ANSI_O
    static let up = kVK_UpArrow, down = kVK_DownArrow
}
