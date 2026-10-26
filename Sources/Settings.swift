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
            "focusHotKey": "ctrl+opt+cmd+f",
            "menuHotKey": "ctrl+opt+cmd+d",
        ])
    }

    /// Black overlay alpha, 0...1.
    var dimLevel: Double {
        get { d.double(forKey: "dimLevel") }
        set { d.set(newValue, forKey: "dimLevel") }
    }
    /// Set from the menu: focus 5–85 min in 5 min steps, rest 1–17 min.
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

    /// e.g. "ctrl+opt+cmd+f". Change with `defaults write com.jayden.dimmer focusHotKey "…"`, then relaunch.
    var focusHotKey: String { d.string(forKey: "focusHotKey") ?? "ctrl+opt+cmd+f" }
    var menuHotKey: String { d.string(forKey: "menuHotKey") ?? "ctrl+opt+cmd+d" }
}
