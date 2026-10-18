import Foundation

/// All user settings, backed by UserDefaults (domain com.jayden.dimmer).
@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "enabled": true,
            "dim": 0.35,
            "hotKey": "ctrl+opt+cmd+d",
        ])
    }

    var enabled: Bool {
        get { d.bool(forKey: "enabled") }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// Black overlay alpha, 0...1.
    var dim: Double {
        get { d.double(forKey: "dim") }
        set { d.set(newValue, forKey: "dim") }
    }
    /// e.g. "ctrl+opt+cmd+d". Change with `defaults write com.jayden.dimmer hotKey "…"`, then relaunch.
    var hotKey: String { d.string(forKey: "hotKey") ?? "ctrl+opt+cmd+d" }
}
