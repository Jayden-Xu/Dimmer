import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHost {
    private let settings = Settings.shared
    private var overlays: Overlays!
    private var tracker: FocusTracker!
    private var menu: MenuController!
    private let hotKeys = HotKey()
    private let breakScreen = BreakScreen()
    let session = Session()
    private(set) var focusHotKey: HotKey.Combo?

    func applicationDidFinishLaunching(_ note: Notification) {
        overlays = Overlays()
        overlays.setDim(settings.dimLevel)
        tracker = FocusTracker(overlays: overlays)
        menu = MenuController(host: self)
        focusHotKey = hotKeys.register(settings.focusHotKey, fallback: "ctrl+opt+cmd+f") { [weak self] in self?.next() }
        hotKeys.register(settings.menuHotKey, fallback: "ctrl+opt+cmd+d") { [weak self] in
            // Nothing to show while the break screen covers the menu bar.
            guard let self, session.phase != .due else { return }
            menu.open()
        }

        session.onChange = { [weak self] in
            self?.menu.close()
            self?.refresh()
        }
        breakScreen.onBegin = { [weak self] in
            self?.session.beginRest()
            return self?.session.end ?? Date()
        }

        tracker.start()
        refresh()
    }

    private func refresh() {
        // While the break screen covers everything, dimming has nothing to do.
        tracker.setActive(session.phase != .due)
        menu.setIcon(focusing: session.phase == .focus && !session.paused)
        switch session.phase {
        case .due: breakScreen.show(focused: session.focusedMinutes)
        case .rest: break // the break screen fades out by itself
        case .idle, .focus: breakScreen.dismiss()
        }
    }

    // MARK: MenuHost

    var axTrusted: Bool { tracker.axTrusted }

    func setDimLevel(_ level: Double) {
        settings.dimLevel = level
        overlays.setDim(level)
    }

    func togglePause() { session.togglePause() }

    /// Hotkey and menu: idle → focus → break screen → rest → idle. On the break screen it is the
    /// same as "begin rest" (a way out if the screen with the button is gone).
    func next() {
        switch session.phase {
        case .idle: session.startFocus()
        case .focus: session.endFocus()
        case .due: breakScreen.begin()
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
