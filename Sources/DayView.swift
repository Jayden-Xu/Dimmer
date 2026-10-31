import AppKit

/// Today as two lanes, midnight at the left to midnight at the right: every focus span in the top lane and
/// every rest span below it, drawn at their real times. Laid out like Pressure's chart (same height, axis and
/// number positions); the time focused and rested are under it, each a number over its label.
final class DayView: NSView {
    private let today: FocusLog.Today
    private let inset: CGFloat
    /// Drawn in Pressure's 172 pt box, lifted by `lift`: ink 10 pt from the top and bottom of the view.
    static let height: CGFloat = 164, lift: CGFloat = 6

    init(_ today: FocusLog.Today, inset: CGFloat) {
        self.today = today
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = 172
        // Every block keeps its ink 10 pt from the top and bottom of its view, in both apps.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let lift = NSAffineTransform()
        lift.translateX(by: 0, yBy: Self.lift)
        lift.concat()
        let x0 = inset, w = bounds.maxX - Ink.trailing - x0
        let now = min(86400, Date().timeIntervalSince(today.day))
        func total(_ spans: [FocusLog.Span]) -> Double { spans.reduce(0) { $0 + max(0, $1.to.timeIntervalSince($1.from)) } }
        let focus = (total: total(today.focus), 0), rest = (total: total(today.rest), 0)

        // Two lanes, midnight at the left to midnight at the right: the spans focused (top) and rested (below),
        // each a block from its start to its end. Same plot area as Pressure's chart.
        let lanes: [(spans: [FocusLog.Span], y: CGFloat, color: NSColor)] = [(today.focus, h - 52, Ink.focus), (today.rest, h - 92, Ink.rest)]
        for lane in lanes {
            let mid = NSBezierPath()
            mid.move(to: NSPoint(x: x0, y: lane.y + 14))
            mid.line(to: NSPoint(x: x0 + w, y: lane.y + 14))
            mid.lineWidth = 0.6
            Ink.tick.withAlphaComponent(0.2).setStroke()
            mid.stroke()
            lane.color.setFill()
            for span in lane.spans {
                let a = max(0, span.from.timeIntervalSince(today.day)), b = min(max(now, a), span.to.timeIntervalSince(today.day))
                let left = x0 + w * CGFloat(a / 86400), right = x0 + w * CGFloat(b / 86400)
                NSRect(x: left, y: lane.y, width: max(1.5, right - left), height: 28).fill()
            }
        }

        // Time axis: a tick every hour, longer at 3 h and 6 h, labeled every 6 h.
        let axisY = h - 96
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: x0, y: axisY))
        axis.line(to: NSPoint(x: x0 + w, y: axisY))
        for k in 0...24 {
            let tx = x0 + w * CGFloat(k) / 24
            axis.move(to: NSPoint(x: tx, y: axisY))
            axis.line(to: NSPoint(x: tx, y: axisY - (k % 6 == 0 ? 7 : k % 3 == 0 ? 5 : 3)))
        }
        axis.lineWidth = 0.7
        Ink.tick.setStroke()
        axis.stroke()
        let caption = Ink.mono(Ink.caption, kern: 1)
        for (k, text) in ["00", "06", "12", "18", "24"].enumerated() {
            Ink.draw(NSAttributedString(string: text, attributes: caption), x: x0 + w * CGFloat(k) / 4, baseline: h - 117, anchor: k == 0 ? 0 : k == 4 ? 1 : 0.5)
        }

        // Time focused and rested today, each a number over its label, centered in its half; a small
        // square in the line's color marks which is which, centered with its label as one group.
        func hhmm(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 3600, Int(seconds) / 60 % 60) }
        for (k, block) in [(hhmm(focus.total), "FOCUS", Ink.focus), (hhmm(rest.total), "REST", Ink.rest)].enumerated() {
            let cx = x0 + w * (k == 0 ? 0.25 : 0.75)
            let label = NSAttributedString(string: block.1, attributes: caption)
            Ink.draw(NSAttributedString(string: block.0, attributes: Ink.mono(Ink.body)), x: cx, baseline: h - 148, anchor: 0.5)
            let groupLeft = cx - (7 + 5 + Ink.width(label)) / 2
            block.2.setFill()
            NSRect(x: groupLeft.rounded(), y: h - 165, width: 7, height: 7).fill()
            Ink.draw(label, x: groupLeft + 12, baseline: h - 165, anchor: 0)
        }
    }
}
