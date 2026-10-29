import AppKit
import QuartzCore

/// The two notices. Both are click-through, never take the keyboard, cover full-screen apps too, last only a
/// couple of seconds and go away by themselves, without sound:
///
///  - a focus ran out by itself: the screen dims a little more and a small copy of the day chart draws itself
///    (focus dark, rest light), ending on how long this focus was. The dim has already been deepening through
///    the last minute (Overlays.startRamp), so the end is expected rather than an event.
///  - the 20-20-20 reminder: two soft lids close a little from the top and bottom of the screen and open again,
///    like a blink, with a small LOOK AWAY line. Nothing to dismiss and nothing to watch to the end.
///
/// Windows exist only while shown.
@MainActor
final class EndScreen {
    private var windows: [NoticeWindow] = []
    private var generation = 0

    var isShowing: Bool { !windows.isEmpty }

    /// `done` runs when the notice has faded: the dim goes back to normal then.
    func focusEnded(minutes: Double, today: FocusLog.Today, done: @escaping () -> Void) {
        dismiss()
        generation += 1
        let shown = generation
        for screen in NSScreen.screens {
            let w = NoticeWindow(frame: screen.frame, veil: 0.4)
            w.contentView?.wantsLayer = true
            w.contentView?.layer?.addSublayer(Self.echo(size: screen.frame.size, scale: screen.backingScaleFactor, today: today, minutes: minutes))
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.9
            for w in windows { w.animator().alphaValue = 1 }
        }
        // One one-shot: fade after the hold.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.dismiss(fade: 1.2, then: done)
            }
        }
    }

    /// A focus or rest begins (menu or hotkey): the header gauge's 240° arc draws itself (one piece, 0.9 s,
    /// slow at both ends), with the word under it. Same for both.
    func started(_ word: String, detail: String?) {
        dismiss()
        generation += 1
        let shown = generation
        for screen in NSScreen.screens {
            let w = NoticeWindow(frame: screen.frame, veil: 0.4)
            w.contentView?.wantsLayer = true
            w.contentView?.layer?.addSublayer(Self.startRing(size: screen.frame.size, scale: screen.backingScaleFactor, word: word, detail: detail))
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            for w in windows { w.animator().alphaValue = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            MainActor.assumeIsolated { if self?.generation == shown { self?.dismiss(fade: 0.5) } }
        }
    }

    /// The 20-20-20 reminder: a blink, 1.8 s in all.
    func blink() {
        dismiss()
        generation += 1
        let shown = generation
        for screen in NSScreen.screens {
            let w = NoticeWindow(frame: screen.frame, veil: 0)
            w.alphaValue = 1
            w.contentView?.wantsLayer = true
            let size = screen.frame.size, lidHeight = size.height * 0.23
            let dark = NSColor(deviceWhite: 0, alpha: 0.72).cgColor, mid = NSColor(deviceWhite: 0, alpha: 0.5).cgColor
            for top in [true, false] {
                let lid = CAGradientLayer()
                lid.bounds = CGRect(x: 0, y: 0, width: size.width, height: lidHeight)
                lid.anchorPoint = CGPoint(x: 0.5, y: top ? 1 : 0)  // closes from the screen's edge
                lid.position = CGPoint(x: size.width / 2, y: top ? size.height : 0)
                lid.colors = top ? [dark, mid] : [mid, dark]
                lid.startPoint = CGPoint(x: 0.5, y: 1)
                lid.endPoint = CGPoint(x: 0.5, y: 0)
                lid.transform = CATransform3DMakeScale(1, 0, 1)
                let close = CAKeyframeAnimation(keyPath: "transform.scale.y")
                close.values = [0, 1, 1, 0]
                close.keyTimes = [0, 0.28, 0.55, 1]
                close.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
                close.duration = 1.8
                close.fillMode = .forwards
                close.isRemovedOnCompletion = false
                lid.add(close, forKey: "blink")
                w.contentView?.layer?.addSublayer(lid)
            }
            let text = CATextLayer()
            text.string = Self.line("LOOK AWAY · 20 SEC", size: 13, kern: 3)
            text.alignmentMode = .center
            text.frame = CGRect(x: 0, y: size.height * 0.07, width: size.width, height: 24)
            text.contentsScale = screen.backingScaleFactor
            text.opacity = 0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0, 1, 1, 0]
            fade.keyTimes = [0, 0.3, 0.4, 0.62, 0.95]
            fade.duration = 1.8
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            text.add(fade, forKey: "fade")
            w.contentView?.layer?.addSublayer(text)
            w.orderFrontRegardless()
            windows.append(w)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
            MainActor.assumeIsolated { if self?.generation == shown { self?.dismiss() } }
        }
    }

    private func dismiss(fade: TimeInterval = 0, then done: (() -> Void)? = nil) {
        guard !windows.isEmpty else { return }
        let gone = windows
        windows = []
        func close() {
            for w in gone { w.orderOut(nil); w.close() }
            trimMemory()
            done?()
        }
        guard fade > 0 else { return close() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            for w in gone { w.animator().alphaValue = 0 }
        }, completionHandler: { close() })
    }

    /// The chart echo: today's cumulative focus (white) and rest (lighter) from midnight to now, drawn on the
    /// same scale as the menu's chart, and "+40 MIN" under it. The lines draw themselves, then the number fades in.
    private static func echo(size: CGSize, scale: CGFloat, today: FocusLog.Today, minutes: Double) -> CALayer {
        let n = 480, cellSeconds = 180.0
        let w = min(520, size.width * 0.42), h = w * 0.4, labelHeight: CGFloat = 80
        let layer = CALayer()
        layer.frame = CGRect(x: (size.width - w) / 2, y: (size.height - h - labelHeight) / 2, width: w, height: h + labelHeight)

        let now = min(86400, Date().timeIntervalSince(today.day))
        let focus = FocusLog.cumulative(today.focus, day: today.day, cells: n, cellSeconds: cellSeconds)
        let rest = FocusLog.cumulative(today.rest, day: today.day, cells: n, cellSeconds: cellSeconds)
        let top = max(3600, (max(focus.total, rest.total) / 3600).rounded(.up) * 3600)
        func point(_ t: Double, _ seconds: Double) -> CGPoint { CGPoint(x: w * CGFloat(t / 86400), y: labelHeight + h * CGFloat(seconds / top)) }
        func curve(_ c: (cells: [Double], total: Double)) -> CGPath {
            let p = CGMutablePath()
            p.move(to: point(0, 0))
            for i in 0..<n where Double(i + 1) * cellSeconds <= now { p.addLine(to: point(Double(i + 1) * cellSeconds, c.cells[i])) }
            p.addLine(to: point(now, c.total))
            return p
        }

        func stroke(_ path: CGPath, alpha: CGFloat, width: CGFloat, dash: [NSNumber]? = nil, draw delay: CFTimeInterval? = nil) {
            let s = CAShapeLayer()
            s.path = path
            s.fillColor = nil
            s.strokeColor = NSColor(white: 1, alpha: alpha).cgColor
            s.lineWidth = width
            s.lineJoin = .round
            s.lineDashPattern = dash
            if let delay {
                let a = CABasicAnimation(keyPath: "strokeEnd")
                a.fromValue = 0
                a.toValue = 1
                a.duration = 1.4
                a.beginTime = CACurrentMediaTime() + delay
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.add(a, forKey: "draw")
            }
            layer.addSublayer(s)
        }
        let guides = CGMutablePath()
        for g in [0.5, 1.0] { guides.move(to: CGPoint(x: 0, y: labelHeight + h * g)); guides.addLine(to: CGPoint(x: w, y: labelHeight + h * g)) }
        let base = CGMutablePath()
        base.move(to: CGPoint(x: 0, y: labelHeight))
        base.addLine(to: CGPoint(x: w, y: labelHeight))
        stroke(guides, alpha: 0.25, width: 1, dash: [1, 3])
        stroke(base, alpha: 0.5, width: 1)
        stroke(curve(rest), alpha: 0.5, width: 2, draw: 0.5)
        stroke(curve(focus), alpha: 0.95, width: 2.6, draw: 0.5)

        let number = NSMutableAttributedString(string: "+" + fmt(minutes), attributes: attributes(56, kern: 1))
        number.append(NSAttributedString(string: " MIN", attributes: attributes(18, kern: 4)))
        let label = CATextLayer()
        label.string = number
        label.alignmentMode = .right
        label.frame = CGRect(x: 0, y: 6, width: w, height: labelHeight - 10)
        label.contentsScale = scale
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0
        reveal.toValue = 1
        reveal.duration = 0.5
        reveal.beginTime = CACurrentMediaTime() + 1.6
        reveal.fillMode = .backwards
        label.add(reveal, forKey: "reveal")
        layer.addSublayer(label)
        return layer
    }

    /// The header gauge's radius and thickness at screen scale, as one unbroken arc, open at the bottom.
    private static func startRing(size: CGSize, scale: CGFloat, word: String, detail: String?) -> CALayer {
        let r = min(120, max(70, size.height * 0.1)), width = 12 * r / Ink.gaugeRadius
        let c = CGPoint(x: size.width / 2, y: size.height / 2 + 16)
        let begin = CACurrentMediaTime() + 0.25
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: r - width / 2, startAngle: 210, endAngle: -30, clockwise: true)
        let arc = CAShapeLayer()
        arc.path = p.cgPath
        arc.fillColor = nil
        arc.strokeColor = NSColor(white: 1, alpha: 0.92).cgColor
        arc.lineWidth = width
        arc.lineCap = .butt
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.9
        draw.beginTime = begin
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)
        arc.add(draw, forKey: "draw")
        layer.addSublayer(arc)
        let text = CATextLayer()
        text.string = line(detail.map { "\(word)  \($0)" } ?? word, size: 15, kern: 5)
        text.alignmentMode = .center
        text.frame = CGRect(x: 0, y: c.y - r - 40, width: size.width, height: 24)
        text.contentsScale = scale
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0
        reveal.toValue = 1
        reveal.duration = 0.35
        reveal.beginTime = begin + 0.45
        reveal.fillMode = .backwards
        text.add(reveal, forKey: "reveal")
        layer.addSublayer(text)
        return layer
    }

    /// "40", or "<1" for less than a minute.
    static func fmt(_ m: Double) -> String { m >= 1 ? "\(Int(m.rounded()))" : "<1" }

    /// Same look as the menu: SF Mono, tracked, white on the dim.
    private static func attributes(_ size: CGFloat, kern: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.92), .kern: kern]
    }

    private static func line(_ s: String, size: CGFloat, kern: CGFloat) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        var a = attributes(size, kern: kern)
        a[.paragraphStyle] = center
        return NSAttributedString(string: s, attributes: a)
    }
}

/// Click-through and never key: typing and clicking go on in the app underneath.
private final class NoticeWindow: NSPanel {
    init(frame: NSRect, veil: Double) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        alphaValue = 0
        colorSpace = .deviceRGB
        backgroundColor = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: veil)
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hand freed heap pages back to the system. Text and window drawing (the notices) leave megabytes of
/// freed-but-dirty malloc pages that would otherwise count until reused.
@MainActor func trimMemory() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
}
