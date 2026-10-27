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

    /// `n` segments around a 240° arc open at the bottom, like Pressure's gauge, lit clockwise from
    /// the lower left. Square-cut: each gap is `gap` wide across the ring, not a fixed angle.
    static func ring(_ n: Int, lit: Int, center c: NSPoint, radius r: CGFloat, width w: CGFloat, gap: CGFloat = 2) {
        let sweep: CGFloat = 240, start: CGFloat = 210
        let gapDeg = gap / (r - w / 2) * 180 / .pi
        let seg = (sweep - CGFloat(n - 1) * gapDeg) / CGFloat(n)
        for i in 0..<n {
            let a0 = start - CGFloat(i) * (seg + gapDeg), a1 = a0 - seg
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
            p.appendArc(withCenter: c, radius: r - w, startAngle: a1, endAngle: a0, clockwise: false)
            p.close()
            (i < lit ? Self.lit : unlit).setFill()
            p.fill()
        }
    }

    /// Draws right-aligned at `right`. Kern also follows the last glyph; leave it out so the text ends flush.
    static func drawRight(_ text: NSAttributedString, right: CGFloat, y: CGFloat) {
        let kern = text.attribute(.kern, at: max(0, text.length - 1), effectiveRange: nil) as? CGFloat ?? 0
        text.draw(at: NSPoint(x: right - text.size().width + kern, y: y))
    }

    /// Redraws `view` on the whole seconds of a countdown to `end`; .common so it runs while the menu tracks.
    static func secondTimer(to end: Date, _ view: NSView) -> Timer {
        let first = Date() + end.timeIntervalSinceNow.truncatingRemainder(dividingBy: 1) + 0.01
        let t = Timer(fire: first, interval: 1, repeats: true) { [weak view] _ in
            MainActor.assumeIsolated { view?.needsDisplay = true }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}

/// A setting as a segmented bar you click or drag, one segment per step (Focus, Rest, Dim):
///
///     Dim                    35%
///     ▬▬▬▬▬▬▬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
///
/// One drawn view instead of an NSSlider plus a text field. Changes apply live while dragging.
/// All bars have 17 segments, so their segments line up in one column grid.
final class StepBarView: NSView {
    static let count = 17
    private static let labelFont = NSFont.menuFont(ofSize: 0)
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

    private let label: String
    private let inset: CGFloat
    private let format: (Int) -> String
    private let onChange: (Int) -> Void
    /// 1...count.
    private var steps: Int { didSet { if steps != oldValue { needsDisplay = true; onChange(steps) } } }

    /// `inset`: where the menu's titles start (see MenuController.rebuild).
    init(_ label: String, steps: Int, inset: CGFloat, format: @escaping (Int) -> String, onChange: @escaping (Int) -> Void) {
        self.label = label
        self.inset = inset
        self.format = format
        self.onChange = onChange
        self.steps = min(Self.count, max(1, steps))
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 31))
        // The menu widens to its widest item; stretch with it so the bar ends at the separators.
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    private var bar: NSRect { NSRect(x: inset, y: 6, width: bounds.maxX - Ink.trailing - inset, height: 3) }

    override func draw(_ dirtyRect: NSRect) {
        let line = Self.labelFont.boundingRectForFont.height
        let y = ((22 - line) / 2).rounded() + bounds.height - 22
        (label as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: [.font: Self.labelFont, .foregroundColor: Ink.text])
        // Mono value, baseline-matched to the label.
        let value = NSAttributedString(string: format(steps), attributes: [.font: Self.valueFont, .foregroundColor: Ink.text])
        Ink.drawRight(value, right: bounds.maxX - Ink.trailing, y: y + Self.labelFont.descender - Self.valueFont.descender)
        Ink.segments(Self.count, lit: steps, in: bar)
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
        let n = Int(((x - bar.minX) / bar.width * CGFloat(Self.count)).rounded(.up))
        steps = min(Self.count, max(1, n))
    }
}

/// Menu header, two ring gauges like Pressure's: the focus / rest on the left, the next 20-20-20
/// reminder on the right. The time sits inside the ring, the caption in its opening.
///
///      ◜‾‾‾‾◝          ◜‾‾‾‾◝
///     ( 38:12 )       ( 12:34 )
///       FOCUS         LOOK AWAY
///
/// 20 segments each (one a minute on the reminder). Ticks once a second only while the menu is
/// open (the view exists only then), and only for a clock that runs. A stopped clock shows its
/// full length (idle: the next focus; rest: no reminder runs).
final class HeaderView: NSView {
    enum Left {
        /// A running or paused focus / rest.
        case clock(caption: String, start: Date, end: Date, pausedLeft: TimeInterval?)
        /// Idle (next focus length) or a finished focus (minutes focused).
        case still(caption: String, value: NSAttributedString, fraction: Double)
    }

    private static let size: CGFloat = 92, thickness: CGFloat = 5, count = 20
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
    private static let captionFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private let left: Left
    private weak var eyes: EyeBreak?
    private let inset: CGFloat
    private var timers: [Timer] = []

    init(_ left: Left, eyes: EyeBreak?, inset: CGFloat) {
        self.left = left
        self.eyes = eyes
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.size + 2))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        timers.forEach { $0.invalidate() }
        timers = []
        guard window != nil else { return }
        if case let .clock(_, _, end, nil) = left { timers.append(Ink.secondTimer(to: end, self)) }
        if let due = eyes?.due { timers.append(Ink.secondTimer(to: due, self)) }
    }

    /// "38:12".
    static func clock(_ seconds: TimeInterval) -> NSAttributedString {
        let s = Int(max(0, seconds).rounded(.up))
        return NSAttributedString(string: String(format: "%02d:%02d", s / 60, s % 60), attributes: Ink.mono(20, kern: 0.5))
    }

    /// "38 MIN": the unit small on the number's baseline.
    static func minutes(_ n: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: n, attributes: Ink.mono(20, kern: 0.5))
        s.addAttribute(.kern, value: 3, range: NSRange(location: s.length - 1, length: 1))
        s.append(NSAttributedString(string: "MIN", attributes: Ink.mono(11, kern: 1)))
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let caption: String, value: NSAttributedString, fraction: Double
        switch left {
        case let .clock(c, start, end, pausedLeft):
            let remaining = pausedLeft ?? max(0, end.timeIntervalSinceNow)
            let total = end.timeIntervalSince(start)
            (caption, value, fraction) = (c, Self.clock(remaining), total > 0 ? 1 - remaining / total : 1)
        case let .still(c, v, f):
            (caption, value, fraction) = (c, v, f)
        }
        let eyeTotal = eyes?.interval ?? 1
        let eyeLeft = eyes?.due.map { max(0, $0.timeIntervalSinceNow) } ?? eyeTotal

        // Left ring starts at the titles' inset, right ring ends at the separators' end.
        let d = Self.size, cy = bounds.maxY - 8 - d / 2
        gauge(center: NSPoint(x: inset + d / 2, y: cy), caption: caption, value: value, fraction: fraction)
        gauge(center: NSPoint(x: bounds.maxX - Ink.trailing - d / 2, y: cy), caption: "LOOK AWAY",
              value: Self.clock(eyeLeft), fraction: 1 - eyeLeft / eyeTotal)
    }

    private func gauge(center c: NSPoint, caption: String, value: NSAttributedString, fraction: Double) {
        let r = Self.size / 2
        let lit = Int((Double(Self.count) * min(1, max(0, fraction))).rounded(.down))
        Ink.ring(Self.count, lit: lit, center: c, radius: r, width: Self.thickness)
        // Kern also follows the last glyph; leave it out when centering.
        func centered(_ s: NSAttributedString, capMiddle y: CGFloat, font: NSFont) {
            let kern = s.attribute(.kern, at: max(0, s.length - 1), effectiveRange: nil) as? CGFloat ?? 0
            s.draw(at: NSPoint(x: (c.x - (s.size().width - kern) / 2).rounded(),
                               y: (y - font.capHeight / 2 + font.descender).rounded()))
        }
        centered(value, capMiddle: c.y + 2, font: Self.valueFont)
        // In the opening, level with the arc's ends.
        centered(NSAttributedString(string: caption, attributes: Ink.mono(11, kern: 1)),
                 capMiddle: c.y - r * 0.5 - 4, font: Self.captionFont)
    }
}

/// Everything the menu needs from the app.
@MainActor
protocol MenuHost: AnyObject {
    var axTrusted: Bool { get }
    var session: Session { get }
    var focusHotKey: HotKey.Combo? { get }
    var eyeBreak: EyeBreak! { get }
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

        let left: HeaderView.Left
        switch session.phase {
        case .idle:
            left = .still(caption: "READY", value: HeaderView.clock(settings.focusMinutes * 60), fraction: 0)
        case .focus, .rest:
            let caption = session.phase == .rest ? "REST" : session.paused ? "PAUSED" : "FOCUS"
            left = .clock(caption: caption, start: session.start, end: session.end, pausedLeft: session.pausedLeft)
        case .due:
            left = .still(caption: "FOCUSED", value: HeaderView.minutes(EndScreen.fmt(session.focusedMinutes)),
                          fraction: session.focusedFraction)
        }
        let header = NSMenuItem()
        header.view = HeaderView(left, eyes: host.eyeBreak, inset: inset)
        menu.addItem(header)
        menu.addItem(.separator())

        switch session.phase {
        case .idle:
            menu.addItem(withHotKey(item("Start Focus", #selector(next)), host.focusHotKey))
        case .focus, .rest:
            let focus = session.phase == .focus
            if focus { menu.addItem(item(session.paused ? "Resume" : "Pause", #selector(togglePause))) }
            menu.addItem(withHotKey(item(focus ? "End Focus" : "End Rest", #selector(next)), host.focusHotKey))
        case .due:
            menu.addItem(withHotKey(item("Start Rest", #selector(next)), host.focusHotKey))
        }

        // Lengths apply from the next focus / rest on; the running one keeps its own.
        menu.addItem(.separator())
        let s = settings
        bar("Focus", steps: Int((s.focusMinutes / 5).rounded()), inset: inset, format: { "\($0 * 5) min" }) { s.focusMinutes = Double($0 * 5) }
        bar("Rest", steps: Int(s.restMinutes.rounded()), inset: inset, format: { "\($0) min" }) { s.restMinutes = Double($0) }
        bar("Dim", steps: Int((s.dimLevel * 20).rounded()), inset: inset, format: { "\($0 * 5)%" }) { [weak self] in
            self?.host?.setDimLevel(Double($0) / 20)
        }

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = loginOn ? .on : .off
        menu.addItem(login)
        if !host.axTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(openAXSettings)))
        }
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func bar(_ label: String, steps: Int, inset: CGFloat, format: @escaping (Int) -> String,
                     onChange: @escaping (Int) -> Void) {
        let it = NSMenuItem()
        it.view = StepBarView(label, steps: steps, inset: inset, format: format, onChange: onChange)
        menu.addItem(it)
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
