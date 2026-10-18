import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon RegisterEventHotKey (needs no extra permission).
@MainActor
final class HotKey {
    struct Combo {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let key: String            // lowercase key name, e.g. "d"
        let cocoaModifiers: NSEvent.ModifierFlags

        /// "⌃⌥⌘D"
        var display: String {
            var s = ""
            if cocoaModifiers.contains(.control) { s += "⌃" }
            if cocoaModifiers.contains(.option) { s += "⌥" }
            if cocoaModifiers.contains(.shift) { s += "⇧" }
            if cocoaModifiers.contains(.command) { s += "⌘" }
            return s + (key.count == 1 ? key.uppercased() : key.capitalized)
        }

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

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var combo: Combo?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, refcon in
            guard let refcon else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { hk.action() }
            return noErr
        }, 1, &spec, refcon, &handler)
    }

    func register(_ string: String) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let c = Combo(string) ?? Combo("ctrl+opt+cmd+d") else { return }
        combo = c
        let id = EventHotKeyID(signature: OSType(0x444D4D52), id: 1) // 'DMMR'
        let status = RegisterEventHotKey(c.keyCode, c.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("Dimmer: RegisterEventHotKey failed (\(status)) for \(string)") }
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
