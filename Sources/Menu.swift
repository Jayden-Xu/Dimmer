import AppKit
import ServiceManagement

/// A label + NSSlider embedded in a menu item; changes apply live while dragging.
final class SliderItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let title: String
    private let format: (Double) -> String
    var onChange: ((Double) -> Void)?

    /// `inset`: where the menu's titles start (see MenuController.rebuild).
    init(title: String, value: Double, min: Double, max: Double, inset: CGFloat, format: @escaping (Double) -> String) {
        self.title = title
        self.format = format
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        label.font = .menuFont(ofSize: 0)
        // Line up with the menu's titles (the field draws 2 pt in); end where separators end.
        label.frame = NSRect(x: inset - 2, y: 24, width: 228 - inset, height: 17)
        label.stringValue = "\(title)  \(format(value))"
        slider.frame = NSRect(x: inset - 2, y: 4, width: 228 - inset, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        // The menu widens to its widest item; stretch with it so the right edge meets the separators.
        autoresizingMask = .width
        label.autoresizingMask = .width
        slider.autoresizingMask = .width
        addSubview(label)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        label.stringValue = "\(title)  \(format(slider.doubleValue))"
        onChange?(slider.doubleValue)
    }
}

/// Menu header while a focus or rest runs, terminal style:
///
///     FOCUS
///     38:12
///     ▮▮▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯▯
///
/// Ticks once a second only while the menu is open (the view exists only then).
final class TimerItemView: NSView {
    private static let segments = 25

    private let inset: CGFloat
    private let caption: String
    private let start: Date
    private let end: Date
    private var timer: Timer?

    init(caption: String, start: Date, end: Date, inset: CGFloat) {
        self.inset = inset
        self.caption = caption
        self.start = start
        self.end = end
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 86))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Fire on the countdown's whole seconds; .common so it runs while the menu tracks.
        let first = Date() + end.timeIntervalSinceNow.truncatingRemainder(dividingBy: 1) + 0.01
        let t = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern]
    }

    override func draw(_ dirtyRect: NSRect) {
        let left = max(0, end.timeIntervalSinceNow)
        let total = end.timeIntervalSince(start)
        let secs = Int(left.rounded(.up))
        let x = inset, w = bounds.width - x - 16
        // Dark grey on a light menu, light grey on a dark one.
        let ink = NSColor.labelColor.withAlphaComponent(0.7)

        NSAttributedString(string: caption, attributes: Self.mono(10, .semibold, .secondaryLabelColor, kern: 1.5))
            .draw(at: NSPoint(x: x, y: 62))

        // 38:12
        NSAttributedString(string: String(format: "%02d:%02d", secs / 60, secs % 60),
                           attributes: Self.mono(30, .medium, ink, kern: 1))
            .draw(at: NSPoint(x: x - 1, y: 20))

        // Segmented progress.
        let n = Self.segments, gap: CGFloat = 2
        let seg = (w - gap * CGFloat(n - 1)) / CGFloat(n)
        let done = total > 0 ? Int((Double(n) * (1 - left / total)).rounded(.down)) : n
        for i in 0..<n {
            (i < done ? ink : NSColor.quaternaryLabelColor).setFill()
            NSRect(x: x + CGFloat(i) * (seg + gap), y: 10, width: seg, height: 6).fill()
        }
    }
}

/// Everything the menu needs from the app.
@MainActor
protocol MenuHost: AnyObject {
    var axTrusted: Bool { get }
    var session: Session { get }
    var focusHotKey: HotKey.Combo? { get }
    func setDimLevel(_ level: Double)
    func next()
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let settings = Settings.shared
    // Sized by the 16 pt icon plus the system's 16 pt padding: 32 pt like most menu bar items.
    // squareLength follows the bar height instead (38 pt on notched screens).
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private weak var host: MenuHost?
    private var focusing: Bool?

    init(host: MenuHost) {
        self.host = host
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(placeholder())
        statusItem.menu = menu
    }

    /// Pop the menu open, as if the menu bar icon was clicked.
    func open() { statusItem.button?.performClick(nil) }

    /// Close the menu (its countdown belongs to the phase that just ended).
    func close() { menu.cancelTracking() }

    /// Redrawn only when that flips.
    func setIcon(focusing: Bool) {
        guard focusing != self.focusing else { return }
        self.focusing = focusing
        statusItem.button?.image = Self.icon(focusing: focusing)
    }

    /// Template bitmap, same picture as the app icon: two dimmed windows behind one bright window.
    /// Three dimmed windows; while focusing the front one lights up (full strength: white on a dark bar).
    private static func icon(focusing: Bool) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        }
        NSColor(deviceWhite: 0, alpha: 0.4).set()
        rect(0.5, 7, 9.5, 8.5, 1.5).fill()
        rect(6, 0.5, 9.5, 8.5, 1.5).fill()
        // Clear a 1 pt gap around the front window so it reads as separate.
        NSGraphicsContext.current?.compositingOperation = .clear
        rect(2.5, 3, 11, 10, 2.5).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        if focusing { NSColor(deviceWhite: 0, alpha: 1).set() }
        rect(3.5, 4, 9, 8, 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = true
        img.accessibilityDescription = "dimmer"
        return img
    }

    // Items are built when the menu opens and dropped when it closes: nothing kept around while idle.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menu.removeAllItems()
                self.menu.addItem(self.placeholder())
                trimMemory()
            }
        }
    }

    private func placeholder() -> NSMenuItem { NSMenuItem(title: "dimmer", action: nil, keyEquivalent: "") }

    private func rebuild() {
        guard let host else { return }
        menu.removeAllItems()
        let session = host.session
        // Titles start 16 pt in, or 24 pt once any item shows a checkmark (the state column).
        // Separators always span 16…224. Our own views follow the titles.
        let loginOn = SMAppService.mainApp.status == .enabled
        let inset: CGFloat = loginOn ? 24 : 16

        switch session.phase {
        case .idle:
            menu.addItem(withHotKey(item("Start Focus · \(BreakScreen.fmt(settings.focusMinutes)) min", #selector(next)), host.focusHotKey))
        case .focus, .rest:
            let focus = session.phase == .focus
            let clock = NSMenuItem()
            clock.view = TimerItemView(caption: focus ? "FOCUS" : "REST", start: session.start, end: session.end, inset: inset)
            menu.addItem(clock)
            menu.addItem(.separator())
            menu.addItem(withHotKey(item(focus ? "End Focus" : "End Rest", #selector(next)), host.focusHotKey))
        case .due:
            break // covered by the break screen
        }

        menu.addItem(.separator())
        let slider = SliderItemView(title: "Dim", value: settings.dimLevel, min: 0.05, max: 0.85, inset: inset) { "\(Int(($0 * 100).rounded()))%" }
        slider.onChange = { [weak self] v in self?.host?.setDimLevel(v) }
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = loginOn ? .on : .off
        menu.addItem(login)
        if !host.axTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAXSettings)))
        }
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func withHotKey(_ it: NSMenuItem, _ combo: HotKey.Combo?) -> NSMenuItem {
        if let c = combo, c.key.count == 1 {
            it.keyEquivalent = c.key
            it.keyEquivalentModifierMask = c.cocoaModifiers
        }
        return it
    }

    // MARK: actions

    @objc private func next() { host?.next() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("dimmer: login item change failed: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
