import AppKit

/// This week as seven rings, Monday first: each a 240° arc of that day's focus, the longest day of the week
/// full, with the day's letter inside and its time under it. Today's ring and text are darker, days still to
/// come are empty.
final class WeekView: NSView {
    private let days: [Double?]
    private let inset: CGFloat
    /// Ink starts 10 pt from the top (the ring) and ends 10 pt from the bottom (the times), like every block.
    static let height: CGFloat = 64
    /// Outer radius and thickness: as wide as seven columns allow, close to the header gauge's proportions.
    private static let radius: CGFloat = 17, thickness: CGFloat = 5

    init(_ days: [Double?], inset: CGFloat) {
        self.days = days
        self.inset = inset
        super.init(frame: NSRect(x: 0, y: 0, width: Ink.menuWidth, height: Self.height))
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func hhmm(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds.rounded()) / 3600, Int(seconds.rounded()) / 60 % 60) }

    override func draw(_ dirtyRect: NSRect) {
        let h = Self.height, x0 = inset, w = bounds.maxX - Ink.trailing - x0
        let known = days.compactMap { $0 }
        let scale = known.max() ?? 0
        let today = days.lastIndex { $0 != nil } ?? 0
        let r = Self.radius, col = w / 7, cy = h - 27
        for (i, day) in days.enumerated() {
            let cx = x0 + col * (CGFloat(i) + 0.5), now = i == today
            // Track, then the day on it; both open at the bottom like the header's gauge.
            func arc(_ sweep: CGFloat, _ color: NSColor) {
                let p = NSBezierPath()
                p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r - Self.thickness / 2, startAngle: 210, endAngle: 210 - sweep, clockwise: true)
                p.lineWidth = Self.thickness
                p.lineCapStyle = .butt
                color.setStroke()
                p.stroke()
            }
            arc(240, Ink.unlit)
            if let day, scale > 0, day > 0 { arc(240 * CGFloat(day / scale), now ? Ink.focus : Ink.lit) }
            let label = Ink.mono(Ink.caption, now ? .medium : .regular, kern: 1)
            Ink.draw(NSAttributedString(string: ["M", "T", "W", "T", "F", "S", "S"][i], attributes: label), x: cx, baseline: cy - 4, anchor: 0.5)
            if let day {
                Ink.draw(NSAttributedString(string: Self.hhmm(day), attributes: Ink.mono(Ink.caption, now ? .medium : .regular)), x: cx, baseline: 13, anchor: 0.5)
            }
        }
    }
}
