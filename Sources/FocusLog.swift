import Foundation

/// Today's focus and rest time, for the menu's day ring: when focus ran (one span per stretch without a
/// pause) and how long rests lasted. Cleared at midnight, so it never grows. Written to UserDefaults when
/// a focus run or a rest stops, and when the menu opens or the app quits (a checkpoint of the one running).
@MainActor
final class FocusLog {
    static let shared = FocusLog()
    struct Today {
        let day: Date
        let spans: [(from: Date, to: Date)]
        /// Seconds of rest.
        let rest: Double
    }

    private let defaults = UserDefaults.standard
    private var day = Date.distantPast
    private var spans: [(from: Date, to: Date)] = []
    private var rest = 0.0

    private init() {
        guard let m = defaults.dictionary(forKey: "focusLog"), let d = m["day"] as? Double,
              let flat = m["spans"] as? [Double] else { return }
        day = Date(timeIntervalSince1970: d)
        spans = stride(from: 0, to: flat.count - 1, by: 2).map { (Date(timeIntervalSince1970: flat[$0]), Date(timeIntervalSince1970: flat[$0 + 1])) }
        rest = m["rest"] as? Double ?? 0
    }

    /// A stretch of running focus ended (paused, ended, or ran out).
    func addRun(from: Date, to: Date) {
        rollover()
        let from = max(from, day)
        guard to > from else { return }
        // A checkpoint continues the span it left off: one span per stretch, however often the menu opens.
        if let last = spans.last, abs(last.to.timeIntervalSince(from)) < 1 {
            spans[spans.count - 1].to = to
        } else {
            spans.append((from, to))
        }
        save()
    }

    /// A rest ended (by hand or at its end).
    func addRest(from: Date, to: Date) {
        rollover()
        rest += max(0, to.timeIntervalSince(max(from, day)))
        save()
    }

    func today() -> Today {
        rollover()
        return Today(day: day, spans: spans, rest: rest)
    }

    /// Yesterday's data goes when the day changes.
    private func rollover() {
        let start = Calendar.current.startOfDay(for: Date())
        guard day != start else { return }
        (day, spans, rest) = (start, [], 0)
    }

    private func save() {
        defaults.set(["day": day.timeIntervalSince1970, "spans": spans.flatMap { [$0.from.timeIntervalSince1970, $0.to.timeIntervalSince1970] },
                      "rest": rest] as [String: Any], forKey: "focusLog")
    }
}
