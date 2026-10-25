import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (needs no extra permission).
@MainActor
final class HotKey {
    struct Combo {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let key: String            // lowercase key name, e.g. "d"
        let cocoaModifiers: NSEvent.ModifierFlags

        /// Parses "ctrl+opt+cmd+d" (also: control, alt, option, command, shift).
        init?(_ string: String) {
            var carbon: UInt32 = 0
            var cocoa: NSEvent.ModifierFlags = []
            var keyName: String?
            for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch part {
                case "ctrl", "control", "⌃": carbon |= UInt32(controlKey); cocoa.insert(.control)
                case "opt", "option", "alt", "⌥": carbon |= UInt32(optionKey); cocoa.insert(.option)
                case "shift", "⇧": carbon |= UInt32(shiftKey); cocoa.insert(.shift)
                case "cmd", "command", "⌘": carbon |= UInt32(cmdKey); cocoa.insert(.command)
                default: keyName = part
                }
            }
            guard let keyName, let code = HotKey.keyCodes[keyName], carbon != 0 else { return nil }
            keyCode = code
            carbonModifiers = carbon
            key = keyName
            cocoaModifiers = cocoa
        }
    }

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let event, let refcon else { return noErr }
            var hk = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk) == noErr else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.actions[hk.id]?() }
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    /// Registers `string` (or `fallback` if it does not parse). Returns the combo for display.
    @discardableResult
    func register(_ string: String, fallback: String, action: @escaping () -> Void) -> Combo? {
        guard let c = Combo(string) ?? Combo(fallback) else { return nil }
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(c.keyCode, c.carbonModifiers, EventHotKeyID(signature: OSType(0x444D4D52), id: id), // 'DMMR'
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("dimmer: RegisterEventHotKey failed (\(status)) for \(string)")
            return nil
        }
        refs.append(ref)
        return c
    }

    /// Virtual key codes (ANSI positions).
    nonisolated static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50, "space": 49, "return": 36, "tab": 48, "escape": 53, "esc": 53,
        ]
        let fkeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fkeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()
}
