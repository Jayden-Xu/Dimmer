import AppKit
import ServiceManagement

/// Menu look, shared with Pressure: text in the label color (black on the light menu), grey only for
/// segments; values in SF Mono; bars cut into square segments.
@MainActor
enum Ink {
    static let text = NSColor.labelColor
    static let lit = NSColor.labelColor.withAlphaComponent(0.5)
    static let unlit = NSColor.labelColor.withAlphaComponent(0.125)
    /// Separators end this far from the right edge; values and bars end there too.
    static let trailing: CGFloat = 16

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium, kern: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: text, .kern: kern]
    }

    /// `n` segments across `rect`, the first `lit` dark. Edges on whole points so every segment is equally crisp.
    static func segments(_ n: Int, lit: Int, in rect: NSRect, gap: CGFloat = 2,
                         on: NSColor? = nil, off: NSColor? = nil) {
        let on = on ?? Self.lit, off = off ?? Self.unlit
        let step = (rect.width + gap) / CGFloat(n)
        for i in 0..<n {
            let left = (rect.minX + CGFloat(i) * step).rounded()
            let right = (rect.minX + CGFloat(i + 1) * step - gap).rounded()
            (i < lit ? on : off).setFill()
            NSRect(x: left, y: rect.minY, width: right - left, height: rect.height).fill()
        }
    }

    /// Draws right-aligned at `right`. Kern also follows the last glyph; leave it out so the text ends flush.
    static func drawRight(_ text: NSAttributedString, right: CGFloat, y: CGFloat) {
        let kern = text.attribute(.kern, at: max(0, text.length - 1), effectiveRange: nil) as? CGFloat ?? 0
        text.draw(at: NSPoint(x: right - text.size().width + kern, y: y))
    }

    /// "40 MIN": the number at the countdown's size, the unit small on its baseline.
    static func minutes(_ n: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: n, attributes: mono(24, kern: 0.5))
        s.addAttribute(.kern, value: 4, range: NSRange(location: s.length - 1, length: 1))
        s.append(NSAttributedString(string: "MIN", attributes: mono(11, kern: 1)))
        return s
    }

    /// The countdown row (menu header), 54 pt tall:
    ///
    ///     FOCUS                38:12      (caption centered on the 24 pt digits)
    ///     ▬▬▬▬▬▬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
    static func readout(caption: String, value: NSAttributedString, fraction: Double, in bounds: NSRect, inset: CGFloat) {
        let x = inset, right = bounds.maxX - trailing
        let timeFont = NSFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let ty: CGFloat = 18
        drawRight(value, right: right, y: ty)
        let middle = ty - timeFont.descender + timeFont.capHeight / 2
        NSAttributedString(string: caption, attributes: mono(11, kern: 1))
            .draw(at: NSPoint(x: x, y: (middle - labelFont.capHeight / 2 + labelFont.descender).rounded()))
        let n = 20
        let lit = Int((Double(n) * min(1, max(0, fraction))).rounded(.down))
        // Thicker than the Dim bar: this one is the readout, that one a control.
        segments(n, lit: lit, in: NSRect(x: x, y: 8, width: right - x, height: 5))
    }
}

/// The dim level as a segmented bar you click or drag, one segment per 5 %:
///
///     Dim                    35%
///     ▬▬▬▬▬▬▬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
///
/// One drawn view instead of an NSSlider plus a text field. Changes apply live while dragging.
final class DimItemView: NSView {
    static let step = 0.05, minSteps = 1, maxSteps = 17  // 5 % … 85 %
    private static let labelFont = NSFont.menuFont(ofSize: 0)
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    private let inset: CGFloat
    private var steps: Int { didSet { if steps != oldValue { needsDisplay = true; onChange?(Double(steps) * Self.step) } } }
    var onChange: ((Double) -> Void)?

    /// `inset`: where the menu's titles start (see MenuController.rebuild).
    init(value: Double, inset: CGFloat) {
        self.inset = inset
        steps = min(Self.maxSteps, max(Self.minSteps, Int((value / Self.step).rounded())))
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 31))
        // The menu widens to its widest item; stretch with it so the bar ends at the separators.
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    private var bar: NSRect { NSRect(x: inset, y: 6, width: bounds.maxX - Ink.trailing - inset, height: 3) }

    override func draw(_ dirtyRect: NSRect) {
        let line = Self.labelFont.boundingRectForFont.height
        let y = ((22 - line) / 2).rounded() + bounds.height - 22
        ("Dim" as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: [.font: Self.labelFont, .foregroundColor: Ink.text])
        // Mono value, baseline-matched to the label.
        let value = NSAttributedString(string: "\(steps * 5)%", attributes: [.font: Self.valueFont, .foregroundColor: Ink.text])
        Ink.drawRight(value, right: bounds.maxX - Ink.trailing, y: y + Self.labelFont.descender - Self.valueFont.descender)
        Ink.segments(Self.maxSteps, lit: steps, in: bar)
    }

    // Own tracking loop: follows the drag even when the pointer leaves the row.
    override func mouseDown(with event: NSEvent) {
        set(from: event)
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            MainActor.assumeIsolated {
                self.set(from: event)
                if event.type == .leftMouseUp { stop.pointee = true }
            }
        }
    }

    private func set(from event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let n = Int(((x - bar.minX) / bar.width * CGFloat(Self.maxSteps)).rounded(.up))
        steps = min(Self.maxSteps, max(Self.minSteps, n))
    }
}

/// Menu header while a focus or rest runs (Ink.readout; FOCUS · PAUSED while paused).
/// Ticks once a second only while the menu is open (the view exists only then), and not at all
/// while paused.
final class TimerItemView: NSView {
    private let inset: CGFloat
    private let caption: String
    private let start: Date
    private let end: Date
    private let pausedLeft: TimeInterval?
    private var timer: Timer?

    init(caption: String, start: Date, end: Date, pausedLeft: TimeInterval? = nil, inset: CGFloat) {
        self.inset = inset
        self.caption = caption
        self.start = start
        self.end = end
        self.pausedLeft = pausedLeft
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil, pausedLeft == nil else { return }
        // Fire on the countdown's whole seconds; .common so it runs while the menu tracks.
        let first = Date() + end.timeIntervalSinceNow.truncatingRemainder(dividingBy: 1) + 0.01
        let t = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func draw(_ dirtyRect: NSRect) {
        let left = pausedLeft ?? max(0, end.timeIntervalSinceNow)
        let total = end.timeIntervalSince(start)
        let secs = Int(left.rounded(.up))
        let time = NSAttributedString(string: String(format: "%02d:%02d", secs / 60, secs % 60), attributes: Ink.mono(24, kern: 0.5))
        Ink.readout(caption: caption, value: time, fraction: total > 0 ? 1 - left / total : 1, in: bounds, inset: inset)
    }
}

/// Menu header between a focus and its rest: how long the focus ran, still and without a timer.
final class FocusedItemView: NSView {
    private let minutes: Double
    private let inset: CGFloat

    init(minutes: Double, inset: CGFloat) {
        self.minutes = minutes
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Ink.readout(caption: "FOCUSED", value: Ink.minutes(EndScreen.fmt(minutes)),
                    fraction: minutes / Settings.shared.focusMinutes, in: bounds, inset: inset)
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
    func togglePause()
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
            menu.addItem(withHotKey(item("Start Focus · \(EndScreen.fmt(settings.focusMinutes)) min", #selector(next)), host.focusHotKey))
        case .focus, .rest:
            let focus = session.phase == .focus
            let clock = NSMenuItem()
            let caption = !focus ? "REST" : session.paused ? "FOCUS · PAUSED" : "FOCUS"
            clock.view = TimerItemView(caption: caption, start: session.start, end: session.end,
                                       pausedLeft: session.pausedLeft, inset: inset)
            menu.addItem(clock)
            menu.addItem(.separator())
            if focus { menu.addItem(item(session.paused ? "Resume" : "Pause", #selector(togglePause))) }
            menu.addItem(withHotKey(item(focus ? "End Focus" : "End Rest", #selector(next)), host.focusHotKey))
        case .due:
            let header = NSMenuItem()
            header.view = FocusedItemView(minutes: session.focusedMinutes, inset: inset)
            menu.addItem(header)
            menu.addItem(.separator())
            menu.addItem(withHotKey(item("Start Rest · \(EndScreen.fmt(settings.restMinutes)) min", #selector(next)), host.focusHotKey))
        }

        menu.addItem(.separator())
        let slider = DimItemView(value: settings.dimLevel, inset: inset)
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
    @objc private func togglePause() { host?.togglePause() }

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
