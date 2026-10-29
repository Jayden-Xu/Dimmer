import AppKit

/// Today as a cumulative line chart, midnight at the left to midnight at the right: the time focused so
/// far climbs while a focus runs and stays flat otherwise, the time rested so far is a lighter line on the
/// same axis, both stop at now. Laid out exactly like Pressure's chart (same height, plot area, axis and
/// number positions); the time focused and rested are under it, each a number over its label.
final class DayView: NSView {
    private let today: FocusLog.Today
    private let inset: CGFloat
    static let height: CGFloat = 172
    private static let cells = 480, cellSeconds = 180.0

    init(_ today: FocusLog.Today, inset: CGFloat) {
        self.today = today
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let n = Self.cells, h = Self.height
        let x0 = inset, w = bounds.maxX - Ink.trailing - x0
        let top = h - 24, bottom = h - 94
        let now = min(86400, Date().timeIntervalSince(today.day))

        // Seconds accumulated at the end of every 3 min cell, and the total.
        func cumulative(_ spans: [FocusLog.Span]) -> (cells: [Double], total: Double) {
            var cells = [Double](repeating: 0, count: n)
            var total = 0.0
            for span in spans {
                let a = span.from.timeIntervalSince(today.day), b = span.to.timeIntervalSince(today.day)
                total += max(0, b - a)
                let first = max(0, Int(a / Self.cellSeconds)), last = min(n, Int(b / Self.cellSeconds) + 1)
                guard first < last else { continue }
                for cell in first..<last {
                    let lo = Double(cell) * Self.cellSeconds
                    cells[cell] += max(0, min(b, lo + Self.cellSeconds) - max(a, lo))
                }
            }
            var sum = 0.0
            return (cells.map { sum += $0; return sum }, total)
        }
        let focus = cumulative(today.focus), rest = cumulative(today.rest)
        // The top guide is the next whole hour above the larger total, at least 1 h.
        let scale = max(3600, (max(focus.total, rest.total) / 3600).rounded(.up) * 3600)
        func point(_ t: Double, _ seconds: Double) -> NSPoint {
            NSPoint(x: x0 + w * CGFloat(t / 86400), y: bottom + CGFloat(seconds / scale) * (top - bottom))
        }
        // From midnight to now: the value at the end of each finished cell, then the total at now.
        func line(_ c: (cells: [Double], total: Double)) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: point(0, 0))
            for i in 0..<n where Double(i + 1) * Self.cellSeconds <= now { p.line(to: point(Double(i + 1) * Self.cellSeconds, c.cells[i])) }
            p.line(to: point(now, c.total))
            return p
        }

        // Guides: the bottom, the middle and the top (dotted).
        for g in 0...2 {
            let gy = bottom + CGFloat(g) * (top - bottom) / 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x0, y: gy))
            p.line(to: NSPoint(x: x0 + w, y: gy))
            if g > 0 { p.setLineDash([1, 2], count: 2, phase: 0) }
            p.lineWidth = 0.6
            Ink.tick.withAlphaComponent(0.35).setStroke()
            p.stroke()
        }

        // The rest line, then the focus line with a fill that fades from the top guide to the bottom.
        let restLine = line(rest)
        restLine.lineWidth = 1.2
        restLine.lineJoinStyle = .round
        Ink.rest.setStroke()
        restLine.stroke()
        let focusLine = line(focus)
        let area = focusLine.copy() as! NSBezierPath
        area.line(to: NSPoint(x: x0 + w * CGFloat(now / 86400), y: bottom))
        area.line(to: NSPoint(x: x0, y: bottom))
        area.close()
        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        NSGradient(starting: Ink.text.withAlphaComponent(0.2), ending: Ink.text.withAlphaComponent(0.01))?
            .draw(from: NSPoint(x: x0, y: top), to: NSPoint(x: x0, y: bottom), options: [])
        NSGraphicsContext.restoreGraphicsState()
        focusLine.lineWidth = 1.2
        focusLine.lineJoinStyle = .round
        Ink.text.setStroke()
        focusLine.stroke()

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
        for (k, block) in [(hhmm(focus.total), "FOCUS", Ink.text), (hhmm(rest.total), "REST", Ink.rest)].enumerated() {
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
