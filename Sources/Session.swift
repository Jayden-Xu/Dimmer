import Foundation

/// idle → focus → due → rest → idle.
///
/// `due`: the focus is over (ran out, or ended early); the rest starts, and counts, from
/// "Start Rest" in the menu or the hotkey. The only timer is one wall-clock one-shot at
/// the end of a focus or a rest (sleep counts; a deadline passed while asleep fires right on wake).
/// A paused focus has no timer at all, only the seconds it had left.
@MainActor
final class Session {
    enum Phase { case idle, focus, due, rest }

    private(set) var phase = Phase.idle
    /// Start and end of the running focus or rest. Resuming a focus shifts both by the pause,
    /// so `end - start` stays the full length and `now - start` the time actually focused.
    private(set) var start = Date.distantPast
    private(set) var end = Date.distantPast
    /// Seconds left in a paused focus; nil while running.
    private(set) var pausedLeft: TimeInterval?
    /// How long the last focus actually ran.
    private(set) var focusedMinutes = 0.0
    private var timer: DispatchSourceTimer?

    var onChange: (() -> Void)?
    /// A focus or rest ran out by itself (not ended by hand): the phase that ended and its minutes.
    var onTimeUp: ((Phase, Double) -> Void)?

    var paused: Bool { pausedLeft != nil }

    func startFocus() {
        run(.focus, minutes: Settings.shared.focusMinutes) { [weak self] in self?.focusRanOut() }
    }

    private func focusRanOut() {
        endFocus()
        onTimeUp?(.focus, focusedMinutes)
    }

    /// Time ran out, or ended early from the menu / hotkey (paused or not).
    func endFocus() {
        guard phase == .focus else { return }
        let total = end.timeIntervalSince(start)
        let left = pausedLeft ?? max(0, end.timeIntervalSinceNow)
        focusedMinutes = (total - left) / 60
        set(.due)
    }

    func togglePause() {
        guard phase == .focus else { return }
        if let left = pausedLeft {
            let total = end.timeIntervalSince(start)
            end = Date() + left
            start = end - total
            pausedLeft = nil
            arm(left) { [weak self] in self?.focusRanOut() }
        } else {
            timer?.cancel()
            timer = nil
            pausedLeft = max(0, end.timeIntervalSinceNow)
        }
        onChange?()
    }

    func beginRest() {
        run(.rest, minutes: Settings.shared.restMinutes) { [weak self] in
            guard let self else { return }
            let minutes = end.timeIntervalSince(start) / 60
            stop()
            onTimeUp?(.rest, minutes)
        }
    }

    func stop() { set(.idle) }

    private func run(_ p: Phase, minutes: Double, then done: @escaping () -> Void) {
        let seconds = minutes * 60
        start = Date()
        end = start + seconds
        set(p)
        arm(seconds, then: done)
    }

    private func arm(_ seconds: TimeInterval, then done: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { MainActor.assumeIsolated { done() } }
        t.schedule(wallDeadline: .now() + seconds, leeway: .seconds(1))
        t.resume()
        timer = t
    }

    private func set(_ p: Phase) {
        timer?.cancel()
        timer = nil
        pausedLeft = nil
        phase = p
        onChange?()
    }
}
