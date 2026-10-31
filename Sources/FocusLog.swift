import Foundation

/// Today's focus and rest, for the menu's day strip: when each ran (one span per stretch without a pause
/// for focus, one per rest). Cleared at midnight, so it never grows; the focus total of each finished day of
/// this week is kept for the menu's week rings (at most 6 numbers). Kept in memory, which is what the
/// menu draws from, and written to UserDefaults when a focus run or a rest stops and when the app quits.
@MainActor
final class FocusLog {
    static let shared = FocusLog()
    typealias Span = (from: Date, to: Date)
    struct Today {
        let day: Date
        let focus: [Span]
        let rest: [Span]
    }

    private let defaults = UserDefaults.standard
    private var day = Date.distantPast
    private var focus: [Span] = []
    private var rest: [Span] = []
    /// Focus seconds of each finished day this week, by the day's start (seconds since 1970).
    private var finished: [Double: Double] = [:]

    private init() {
        guard let m = defaults.dictionary(forKey: "focusLog"), let d = m["day"] as? Double else { return }
        day = Date(timeIntervalSince1970: d)
        focus = Self.spans(m["spans"] as? [Double])
        rest = Self.spans(m["rests"] as? [Double])
        finished = (m["week"] as? [String: Double] ?? [:]).reduce(into: [:]) { if let k = Double($1.key) { $0[k] = $1.value } }
    }

    /// A stretch of running focus ended (paused, ended, or ran out), or is being checkpointed (`persist` false).
    func addRun(from: Date, to: Date, persist: Bool = true) {
        rollover()
        Self.add(&focus, from: max(from, day), to: to)
        if persist { save() }
    }

    /// A rest ended (by hand), or is being checkpointed (`persist` false).
    func addRest(from: Date, to: Date, persist: Bool = true) {
        rollover()
        Self.add(&rest, from: max(from, day), to: to)
        if persist { save() }
    }

    func today() -> Today {
        rollover()
        return Today(day: day, focus: focus, rest: rest)
    }

    /// Focus seconds of each day of this week, Monday first; nil for the days still to come.
    func week() -> [Double?] {
        rollover()
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let start = cal.dateInterval(of: .weekOfYear, for: day)?.start else { return [] }
        let total = focus.reduce(0) { $0 + max(0, $1.to.timeIntervalSince($1.from)) }
        return (0..<7).map { k in
            guard let d = cal.date(byAdding: .day, value: k, to: start) else { return nil }
            if d == day { return total }
            return d > day ? nil : finished[d.timeIntervalSince1970] ?? 0
        }
    }

    /// The day chart's top, in seconds: the first step at or above `seconds`, from 30 min up by ×1.5 and ×2 in
    /// turn (30 min, 45 min, 1 h, 1.5 h, 2 h, 3 h, 4 h, 6 h…), so the higher line always reaches at least 2/3
    /// of the plot. The menu's chart and the end-of-focus echo share it, so they draw the same shape.
    static func chartTop(_ seconds: Double) -> Double {
        var top = 1800.0
        while top * 1.5 < seconds { top *= 2 }
        if top < seconds { top *= 1.5 }
        return top
    }

    /// Seconds accumulated by the end of each `cellSeconds` cell of `day`, and the total. The day chart in the
    /// menu and the end-of-focus echo draw the same curves from this.
    static func cumulative(_ spans: [Span], day: Date, cells n: Int, cellSeconds: Double) -> (cells: [Double], total: Double) {
        var cells = [Double](repeating: 0, count: n)
        var total = 0.0
        for span in spans {
            let a = span.from.timeIntervalSince(day), b = span.to.timeIntervalSince(day)
            total += max(0, b - a)
            let first = max(0, Int(a / cellSeconds)), last = min(n, Int(b / cellSeconds) + 1)
            guard first < last else { continue }
            for cell in first..<last {
                let lo = Double(cell) * cellSeconds
                cells[cell] += max(0, min(b, lo + cellSeconds) - max(a, lo))
            }
        }
        var sum = 0.0
        return (cells.map { sum += $0; return sum }, total)
    }

    /// A checkpoint continues the span it left off: one span per stretch, however often the menu opens.
    private static func add(_ spans: inout [Span], from: Date, to: Date) {
        guard to > from else { return }
        if let last = spans.last, abs(last.to.timeIntervalSince(from)) < 1 {
            spans[spans.count - 1].to = to
        } else {
            spans.append((from, to))
        }
    }

    private static func spans(_ flat: [Double]?) -> [Span] {
        guard let flat else { return [] }
        return stride(from: 0, to: flat.count - 1, by: 2).map { (Date(timeIntervalSince1970: flat[$0]), Date(timeIntervalSince1970: flat[$0 + 1])) }
    }

    private static func flat(_ spans: [Span]) -> [Double] {
        spans.flatMap { [$0.from.timeIntervalSince1970, $0.to.timeIntervalSince1970] }
    }

    /// Yesterday's data goes when the day changes.
    private func rollover() {
        let start = Calendar.current.startOfDay(for: Date())
        guard day != start else { return }
        var cal = Calendar.current
        cal.firstWeekday = 2
        let weekStart = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        let total = focus.reduce(0) { $0 + max(0, $1.to.timeIntervalSince($1.from)) }
        if total > 0, day != .distantPast { finished[day.timeIntervalSince1970] = total }
        finished = finished.filter { $0.key >= weekStart.timeIntervalSince1970 }
        (day, focus, rest) = (start, [], [])
        save()
    }

    private func save() {
        defaults.set(["day": day.timeIntervalSince1970, "spans": Self.flat(focus), "rests": Self.flat(rest),
                      "week": Dictionary(uniqueKeysWithValues: finished.map { (String($0.key), $0.value) })] as [String: Any], forKey: "focusLog")
    }
}
