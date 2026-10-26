import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHost {
    private let settings = Settings.shared
    private var overlays: Overlays!
    private var tracker: FocusTracker!
    private var menu: MenuController!
    private let hotKeys = HotKey()
    private let endScreen = EndScreen()
    let session = Session()
    private(set) var focusHotKey: HotKey.Combo?

    func applicationDidFinishLaunching(_ note: Notification) {
        overlays = Overlays()
        overlays.setDim(settings.dimLevel)
        tracker = FocusTracker(overlays: overlays)
        menu = MenuController(host: self)
        focusHotKey = hotKeys.register(settings.focusHotKey, fallback: "ctrl+opt+cmd+f") { [weak self] in self?.next() }
        hotKeys.register(settings.menuHotKey, fallback: "ctrl+opt+cmd+d") { [weak self] in self?.menu.open() }

        session.onChange = { [weak self] in
            self?.menu.close()
            self?.refresh()
        }
        session.onTimeUp = { [weak self] phase, minutes in
            self?.endScreen.show(phase == .focus ? "FOCUSED" : "RESTED", minutes: minutes)
        }

        tracker.start()
        tracker.setActive(true)
        refresh()
    }

    private func refresh() {
        menu.setIcon(focusing: session.phase == .focus && !session.paused)
    }

    // MARK: MenuHost

    var axTrusted: Bool { tracker.axTrusted }

    func setDimLevel(_ level: Double) {
        settings.dimLevel = level
        overlays.setDim(level)
    }

    func togglePause() { session.togglePause() }

    /// Hotkey and menu: idle → focus → (focus over) → rest → idle.
    func next() {
        switch session.phase {
        case .idle: session.startFocus()
        case .focus: session.endFocus()
        case .due: session.beginRest()
        case .rest: session.stop()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
