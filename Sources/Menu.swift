import AppKit
import ServiceManagement

/// Menu look, shared with Pressure: text in the label color (black on the light menu), grey only for
/// segments; values in SF Mono; bars cut into square segments.
@MainActor
enum Ink {
    static let text = NSColor.labelColor
    /// Menu width, the same as Pressure's.
    static let menuWidth: CGFloat = 320
    static let gaugeRadius: CGFloat = 52
    /// The header's time is centered in this width, ending at the separators.
    static let columnWidth: CGFloat = 120
    /// The whole menu is SF Mono medium in three sizes: the header's time, everything else you read
    /// (rows, stats, menu items), and captions (labels, axes), which are also spaced out.
    static let hero: CGFloat = 38, body: CGFloat = 14, caption: CGFloat = 11
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: body, weight: .medium)
    static let lit = NSColor.labelColor.withAlphaComponent(0.5)
    static let unlit = NSColor.labelColor.withAlphaComponent(0.125)
    /// The last lit segment: the gauge's scan head.
    static let head = NSColor.labelColor.withAlphaComponent(0.9)
    /// Hairlines: guides and tick scales.
    static let hair = NSColor.labelColor.withAlphaComponent(0.14)
    static let tick = NSColor.labelColor.withAlphaComponent(0.4)
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

    /// `n` segments around an arc of `sweep` degrees open at the bottom, lit clockwise from the left.
    /// Square-cut: each gap is `gap` wide across the ring, not a fixed angle.
    static func ring(_ n: Int, lit: Int, center c: NSPoint, radius r: CGFloat, width w: CGFloat,
                     gap: CGFloat = 2, sweep: CGFloat = 240) {
        let start = 90 + sweep / 2
        let gapDeg = gap / (r - w / 2) * 180 / .pi
        let seg = (sweep - CGFloat(n - 1) * gapDeg) / CGFloat(n)
        for i in 0..<n {
            let a0 = start - CGFloat(i) * (seg + gapDeg), a1 = a0 - seg
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
            p.appendArc(withCenter: c, radius: r - w, startAngle: a1, endAngle: a0, clockwise: false)
            p.close()
            (i < lit ? (i == lit - 1 ? head : Self.lit) : unlit).setFill()
            p.fill()
        }
    }

    /// A scale outside a 240° gauge open at the bottom, a tick every `step` degrees, every fifth longer.
    static func ticks(center c: NSPoint, radius r: CGFloat, step: CGFloat) {
        let n = Int((240 / step).rounded())
        let p = NSBezierPath()
        for k in 0...n {
            let a = (210 - CGFloat(k) * step) * .pi / 180, len: CGFloat = k % 5 == 0 || k == n ? 4 : 2.2
            p.move(to: NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
            p.line(to: NSPoint(x: c.x + (r + len) * cos(a), y: c.y + (r + len) * sin(a)))
        }
        p.lineWidth = 0.7
        tick.setStroke()
        p.stroke()
    }

    /// Draws right-aligned at `right`. Kern also follows the last glyph; leave it out so the text ends flush.
    static func drawRight(_ text: NSAttributedString, right: CGFloat, y: CGFloat) {
        let kern = text.attribute(.kern, at: max(0, text.length - 1), effectiveRange: nil) as? CGFloat ?? 0
        text.draw(at: NSPoint(x: right - text.size().width + kern, y: y))
    }

    /// Ink width: kern also follows the last glyph; leave it out.
    static func width(_ text: NSAttributedString) -> CGFloat {
        text.size().width - (text.attribute(.kern, at: max(0, text.length - 1), effectiveRange: nil) as? CGFloat ?? 0)
    }

    /// Draws with its first font's baseline at `baseline`; `anchor` 0 starts it at `x`, 0.5 centers it, 1 ends it there.
    static func draw(_ text: NSAttributedString, x: CGFloat, baseline: CGFloat, anchor: CGFloat) {
        let descender = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.descender ?? 0
        text.draw(at: NSPoint(x: (x - width(text) * anchor).rounded(), y: baseline + descender))
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
/// All bars have 20 segments, so their segments line up in one column grid.
final class StepBarView: NSView {
    static let count = 20
    private static let font = Ink.bodyFont

    private let label: String
    private let inset: CGFloat
    private let format: (Int) -> String
    private let onChange: (Int) -> Void
    /// The fewest lit segments: 1, or 0 when an empty bar means something (Dim off).
    private let least: Int
    /// least...count.
    private var steps: Int { didSet { if steps != oldValue { needsDisplay = true; onChange(steps) } } }

    /// `inset`: where the menu's titles start (see MenuController.rebuild).
    init(_ label: String, steps: Int, least: Int = 1, inset: CGFloat, format: @escaping (Int) -> String,
         onChange: @escaping (Int) -> Void) {
        self.label = label
        self.least = least
        self.inset = inset
        self.format = format
        self.onChange = onChange
        self.steps = min(Self.count, max(least, steps))
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: 36))
        // The menu widens to its widest item; stretch with it so the bar ends at the separators.
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    private var bar: NSRect { NSRect(x: inset, y: 7, width: bounds.maxX - Ink.trailing - inset, height: 4) }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawText(label, format(steps), inset: inset, in: bounds)
        Ink.segments(Self.count, lit: steps, in: bar)
    }

    /// Name at the titles' inset, value at the right end, on one baseline 21 above the bottom; the bar is below it.
    static func drawText(_ label: String, _ value: String, inset: CGFloat, in bounds: NSRect) {
        let y = 21 + font.descender
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ink.text]
        (label as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: attributes)
        Ink.drawRight(NSAttributedString(string: value, attributes: attributes), right: bounds.maxX - Ink.trailing, y: y)
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
        // Left of the bar's start (drag all the way left) is 0 lit.
        steps = min(Self.count, max(least, n))
    }
}

/// Menu header, laid out like Pressure's: a two-ring gauge over the phase at the left edge, the time in
/// large mono over the eye countdown at the right edge — like the rows' label left, value right.
///
///     ◜‾‾◝        26:40
///     FOCUS    EYE 12:34
///
/// Outer ring: the focus / rest clock, 10 segments. Inner: the next 20-20-20 reminder, 20 segments,
/// one a minute; during a rest no reminder runs, so it stands at full length with an empty ring.
/// Both rings span 240°, open at the bottom, like the menu bar gauge. Ticks once a second only while
/// the menu is open (the view exists only then), and only for the countdowns that run.
final class HeaderView: NSView {
    enum Clock {
        /// A running or paused focus / rest.
        case running(caption: String, start: Date, end: Date, pausedLeft: TimeInterval?)
        /// Idle (next focus length) or a finished focus (minutes focused).
        case still(caption: String, value: NSAttributedString, fraction: Double)
    }

    private static let height: CGFloat = 126
    private let clock: Clock
    /// Where the menu's titles start, so the columns split the same span as the rows.
    private let inset: CGFloat
    private weak var eyes: EyeBreak?
    private var timers: [Timer] = []

    init(_ clock: Clock, eyes: EyeBreak?, inset: CGFloat) {
        self.clock = clock
        self.inset = inset
        self.eyes = eyes
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        timers.forEach { $0.invalidate() }
        timers = []
        guard window != nil else { return }
        // Each countdown redraws on its own whole seconds.
        if case let .running(_, _, end, nil) = clock { timers.append(Ink.secondTimer(to: end, self)) }
        if let due = eyes?.due { timers.append(Ink.secondTimer(to: due, self)) }
    }

    /// "38:12".
    static func mmss(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func clock(_ seconds: TimeInterval) -> NSAttributedString {
        NSAttributedString(string: mmss(seconds), attributes: Ink.mono(Ink.hero, kern: 0.5))
    }

    /// "38 MIN": the unit small on the number's baseline.
    static func minutes(_ n: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: n, attributes: Ink.mono(Ink.hero, kern: 0.5))
        s.addAttribute(.kern, value: 3, range: NSRange(location: s.length - 1, length: 1))
        s.append(NSAttributedString(string: "MIN", attributes: Ink.mono(Ink.caption, kern: 1)))
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let caption: String, value: NSAttributedString, fraction: Double
        switch clock {
        case let .running(c, start, end, pausedLeft):
            let remaining = pausedLeft ?? max(0, end.timeIntervalSinceNow)
            let total = end.timeIntervalSince(start)
            (caption, value, fraction) = (c, Self.clock(remaining), total > 0 ? 1 - remaining / total : 1)
        case let .still(c, v, f):
            (caption, value, fraction) = (c, v, f)
        }
        let eyeTotal = eyes?.interval ?? 1
        let eyeLeft = eyes?.due.map { max(0, $0.timeIntervalSinceNow) } ?? eyeTotal

        let left = inset, right = bounds.maxX - Ink.trailing

        // Same gauge size and place as Pressure's: lower ends 16 above the labels' baseline.
        let r = Ink.gaugeRadius, c = NSPoint(x: left + r, y: 30 + r / 2)
        func lit(_ n: Int, _ f: Double) -> Int { Int((Double(n) * min(1, max(0, f))).rounded(.down)) }
        Ink.ring(10, lit: lit(10, fraction), center: c, radius: r, width: 12, gap: 3)
        Ink.ring(20, lit: lit(20, 1 - eyeLeft / eyeTotal), center: c, radius: 36, width: 7, gap: 2.5)
        Ink.ticks(center: c, radius: r + 5, step: 6)

        // Each label centered under its gauge or time; labels share one baseline.
        // The 38 pt time is centered on the gauge's height; its column ends at the separators.
        let label = Ink.mono(Ink.caption, kern: 1)
        let eye = NSAttributedString(string: "EYE " + Self.mmss(eyeLeft), attributes: label)
        let x2 = right - Ink.columnWidth / 2
        Ink.draw(NSAttributedString(string: caption, attributes: label), x: c.x, baseline: 14, anchor: 0.5)
        Ink.draw(eye, x: x2, baseline: 14, anchor: 0.5)
        Ink.draw(value, x: x2, baseline: c.y + r / 4 - 14, anchor: 0.5)
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

        let clock: HeaderView.Clock
        switch session.phase {
        case .idle:
            clock = .still(caption: "READY", value: HeaderView.clock(settings.focusMinutes * 60), fraction: 0)
        case .focus, .rest:
            let caption = session.phase == .rest ? "REST" : session.paused ? "PAUSED" : "FOCUS"
            clock = .running(caption: caption, start: session.start, end: session.end, pausedLeft: session.pausedLeft)
        case .due:
            clock = .still(caption: "DONE", value: HeaderView.minutes(EndScreen.fmt(session.focusedMinutes)),
                           fraction: session.focusedFraction)
        }
        let header = NSMenuItem()
        header.view = HeaderView(clock, eyes: host.eyeBreak, inset: inset)
        menu.addItem(header)
        menu.addItem(.separator())
        // Opening the menu saves the running focus or rest first, then draws from what is saved.
        session.checkpoint()
        let day = NSMenuItem()
        day.view = DayView(FocusLog.shared.today(), inset: inset)
        menu.addItem(day)
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
        bar("Dim", steps: Int((s.dimLevel * 20).rounded()), least: 0, inset: inset, format: { "\($0 * 5)%" }) { [weak self] in
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

    private func bar(_ label: String, steps: Int, least: Int = 1, inset: CGFloat, format: @escaping (Int) -> String,
                     onChange: @escaping (Int) -> Void) {
        let it = NSMenuItem()
        it.view = StepBarView(label, steps: steps, least: least, inset: inset, format: format, onChange: onChange)
        menu.addItem(it)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.attributedTitle = NSAttributedString(string: title, attributes: [.font: Ink.bodyFont])
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
