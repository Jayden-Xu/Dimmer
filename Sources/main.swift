import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuHost {
    private let settings = Settings.shared
    private var overlays: Overlays!
    private var tracker: FocusTracker!
    private var menu: MenuController!
    private var hotKey: HotKey!

    func applicationDidFinishLaunching(_ note: Notification) {
        overlays = Overlays()
        overlays.setDim(settings.dim)
        overlays.sync()

        tracker = FocusTracker(overlays: overlays)
        menu = MenuController(host: self)

        hotKey = HotKey { [weak self] in self?.toggleEnabled() }
        hotKey.register(settings.hotKey)

        tracker.start()
    }

    // MARK: MenuHost

    var axTrusted: Bool { tracker.axTrusted }
    var hotKeyDisplay: HotKey.Combo? { hotKey.combo }

    func toggleEnabled() {
        settings.enabled.toggle()
        if settings.enabled {
            tracker.setNeedsUpdate()
        } else {
            overlays.hideAll()
        }
    }

    func setDim(_ dim: Double) {
        settings.dim = dim
        overlays.setDim(dim)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
