import AppKit

/// Today as a timeline strip, midnight at the left to midnight at the right: one cell per 3 min (about a
/// pixel), dark where focus ran (a cell with at least a minute of it), a small triangle where now is, an
/// hourly time axis, and the time focused and rested under it, each a number over its label.
final class DayView: NSView {
    private let today: FocusLog.Today
    private let inset: CGFloat
    static let height: CGFloat = 126
    private static let cells = 480, cellSeconds = 180.0, litSeconds = 60.0

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
        let now = Date().timeIntervalSince(today.day)

        // Seconds of focus per cell.
        var covered = [Double](repeating: 0, count: n)
        var total = 0.0
        for span in today.spans {
            let a = span.from.timeIntervalSince(today.day), b = span.to.timeIntervalSince(today.day)
            total += max(0, b - a)
            let first = max(0, Int(a / Self.cellSeconds)), last = min(n, Int(b / Self.cellSeconds) + 1)
            guard first < last else { continue }
            for cell in first..<last {
                let lo = Double(cell) * Self.cellSeconds
                covered[cell] += max(0, min(b, lo + Self.cellSeconds) - max(a, lo))
            }
        }

        // The strip: the empty day, then each stretch of lit cells as one block.
        Ink.unlit.setFill()
        NSRect(x: x0, y: h - 46, width: w, height: 36).fill()
        Ink.head.setFill()
        var cell = 0
        while cell < n {
            guard covered[cell] >= Self.litSeconds else { cell += 1; continue }
            var end = cell
            while end < n, covered[end] >= Self.litSeconds { end += 1 }
            NSRect(x: x0 + w * CGFloat(cell) / CGFloat(n), y: h - 46, width: w * CGFloat(end - cell) / CGFloat(n), height: 36).fill()
            cell = end
        }
        // Now: a triangle above the strip.
        let nx = x0 + w * CGFloat(min(1, now / 86400))
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: nx - 3, y: h - 2))
        tri.line(to: NSPoint(x: nx + 3, y: h - 2))
        tri.line(to: NSPoint(x: nx, y: h - 8))
        tri.close()
        Ink.text.setFill()
        tri.fill()

        // Time axis: a tick every hour, longer at 3 h and 6 h, labeled every 6 h.
        let axisY = h - 48
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
            Ink.draw(NSAttributedString(string: text, attributes: caption), x: x0 + w * CGFloat(k) / 4, baseline: h - 69, anchor: k == 0 ? 0 : k == 4 ? 1 : 0.5)
        }

        // Time focused and rested today, each a number over its label, centered in its half.
        func hhmm(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 3600, Int(seconds) / 60 % 60) }
        for (k, block) in [(hhmm(total), "FOCUS"), (hhmm(today.rest), "REST")].enumerated() {
            let cx = x0 + w * (k == 0 ? 0.25 : 0.75)
            Ink.draw(NSAttributedString(string: block.0, attributes: Ink.mono(Ink.body)), x: cx, baseline: h - 100, anchor: 0.5)
            Ink.draw(NSAttributedString(string: block.1, attributes: caption), x: cx, baseline: h - 117, anchor: 0.5)
        }
    }
}
