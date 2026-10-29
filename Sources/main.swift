import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHost {
    private let settings = Settings.shared
    private var overlays: Overlays!
    private var tracker: FocusTracker!
    private var menu: MenuController!
    private let hotKeys = HotKey()
    private let endScreen = EndScreen()
    private(set) var eyeBreak: EyeBreak!
    let session = Session()
    private(set) var focusHotKey: HotKey.Combo?
    private let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

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
        eyeBreak = EyeBreak(minutes: settings.eyeMinutes) { [weak self] in
            // Skip if the end-of-focus notice is up; the next one comes 20 minutes later.
            guard let self, !endScreen.isShowing else { return }
            endScreen.blink()
        }
        session.onApproach = { [weak self] seconds in self?.overlays.startRamp(over: seconds) }
        session.onApproachCancel = { [weak self] in self?.overlays.resetRamp() }
        session.onTimeUp = { [weak self] minutes in
            guard let self else { return }
            endScreen.focusEnded(minutes: minutes, today: FocusLog.shared.today()) { [weak self] in self?.overlays.resetRamp() }
        }

        // kill / pkill (and so a reinstall) end the process without applicationWillTerminate: save first.
        signal(SIGTERM, SIG_IGN)
        termination.setEventHandler { [weak self] in
            self?.session.checkpoint(persist: true)
            NSApp.terminate(nil)
        }
        termination.activate()

        // Sleep or power off ends the session (a focus mustn't keep counting while the lid is shut, and a rest
        // has no end of its own): what it accumulated is logged and written.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.endSession() }
            }
        }

        tracker.start()
        tracker.setActive(true)
        refresh()
    }

    func applicationWillTerminate(_ note: Notification) {
        session.checkpoint(persist: true)
    }

    private func refresh() {
        menu.setIcon(focusing: session.phase == .focus && !session.paused)
        eyeBreak.setResting(session.phase == .rest)
    }

    // MARK: MenuHost

    var axTrusted: Bool { tracker.axTrusted }

    func setDimLevel(_ level: Double) {
        let wasOff = settings.dimLevel == 0
        settings.dimLevel = level
        overlays.setDim(level)
        if wasOff && level > 0 { tracker.update() } // show the overlays again
    }

    func togglePause() { session.togglePause() }

    /// Hotkey and menu: focus and rest follow each other (idle → focus → rest → focus ...), each start showing its notice.
    func next() {
        switch session.phase {
        case .idle: beginFocus()
        case .focus:
            session.endFocus()
            beginRest()
        case .due: beginRest()
        case .rest:
            session.stop()
            beginFocus()
        }
    }

    /// Menu only: back to idle, showing nothing.
    func stop() {
        session.endFocus()
        session.stop()
    }

    private func beginFocus() {
        session.startFocus()
        endScreen.started("FOCUS", detail: EndScreen.fmt(settings.focusMinutes) + " MIN")
    }

    private func beginRest() {
        session.beginRest()
        endScreen.started("REST", detail: nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
