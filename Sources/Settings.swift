import Foundation

/// All user settings, backed by UserDefaults (domain com.jayden.dimmer).
@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "dimLevel": 0.35,
            "focusMinutes": 40,
            "restMinutes": 10,
            "eyeMinutes": 20,
            "focusHotKey": "ctrl+opt+cmd+f",
            "menuHotKey": "ctrl+opt+cmd+d",
        ])
    }

    /// Black overlay alpha, 0...1 in 5 % steps: 0 = no dimming (overlays hidden), 1 = solid black.
    var dimLevel: Double {
        get { d.double(forKey: "dimLevel") }
        set { d.set(newValue, forKey: "dimLevel") }
    }
    /// Set from the menu: focus 5–100 min in 5 min steps, rest 1–20 min.
    /// Test runs can override them with launch arguments (never stored):
    /// `open dimmer.app --args -focusMinutes 0.1 -restMinutes 0.1`.
    var focusMinutes: Double {
        get { max(0.05, d.double(forKey: "focusMinutes")) }
        set { d.set(newValue, forKey: "focusMinutes") }
    }
    var restMinutes: Double {
        get { max(0.05, d.double(forKey: "restMinutes")) }
        set { d.set(newValue, forKey: "restMinutes") }
    }
    /// 20-20-20 reminder interval; not in the menu, only a launch argument for tests (`-eyeMinutes 0.1`).
    var eyeMinutes: Double { max(0.05, d.double(forKey: "eyeMinutes")) }

    /// e.g. "ctrl+opt+cmd+f". Change with `defaults write com.jayden.dimmer focusHotKey "…"`, then relaunch.
    var focusHotKey: String { d.string(forKey: "focusHotKey") ?? "ctrl+opt+cmd+f" }
    var menuHotKey: String { d.string(forKey: "menuHotKey") ?? "ctrl+opt+cmd+d" }
}
