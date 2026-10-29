import Foundation

/// idle → focus → due → rest → idle.
///
/// `due`: the focus is over (ran out, or ended early); the rest starts, and counts, from
/// "Start Rest" in the menu or the hotkey. A rest has no length and no timer: it runs until it is
/// ended by hand. The only timer is one wall-clock one-shot at the end of a focus (sleep counts; a
/// deadline passed while asleep fires right on wake). A paused focus has no timer at all, only the
/// seconds it had left.
@MainActor
final class Session {
    enum Phase { case idle, focus, due, rest }

    private(set) var phase = Phase.idle
    /// Start and end of the running focus (a rest has only a start; its end is never). Resuming a focus
    /// shifts both by the pause, so `end - start` stays the full length and `now - start` the time
    /// actually focused.
    private(set) var start = Date.distantPast
    private(set) var end = Date.distantPast
    /// Seconds left in a paused focus; nil while running.
    private(set) var pausedLeft: TimeInterval?
    /// How long the last focus actually ran, and that as a share of its planned length.
    private(set) var focusedMinutes = 0.0
    private(set) var focusedFraction = 0.0
    /// When the current stretch of running focus began; nil while paused or outside a focus.
    private(set) var runStart: Date?
    /// Up to where the running rest has been logged.
    private var restMark: Date?
    private var timer: DispatchSourceTimer?

    var onChange: (() -> Void)?
    /// A focus ran out by itself (not ended by hand): its minutes.
    var onTimeUp: ((Double) -> Void)?
    /// The last stretch of a focus (a minute, or all of a shorter one) begins: the dim starts to deepen over this long.
    var onApproach: ((TimeInterval) -> Void)?
    /// The approach was abandoned (paused, ended by hand, slept): the dim goes back.
    var onApproachCancel: (() -> Void)?
    private var approachTimer: DispatchSourceTimer?
    private var approaching = false
    private static let approachSeconds = 60.0

    var paused: Bool { pausedLeft != nil }

    func startFocus() {
        run(.focus, minutes: Settings.shared.focusMinutes) { [weak self] in self?.focusRanOut() }
    }

    private func focusRanOut() {
        approaching = false  // ending by itself: the end notice takes over the dim and puts it back when it is done
        endFocus()
        onTimeUp?(focusedMinutes)
    }

    /// Time ran out, or ended early from the menu / hotkey (paused or not).
    func endFocus() {
        guard phase == .focus else { return }
        let total = end.timeIntervalSince(start)
        let left = pausedLeft ?? max(0, end.timeIntervalSinceNow)
        focusedMinutes = (total - left) / 60
        focusedFraction = total > 0 ? (total - left) / total : 1
        if let runStart { FocusLog.shared.addRun(from: runStart, to: min(Date(), end)) }
        runStart = nil
        set(.due)
    }

    /// Adds what the running focus or rest has accumulated so far to the log, so the menu's day strip and
    /// totals are current. The menu calls it without `persist` (memory only, nothing written); quit and
    /// SIGTERM call it with, so nothing is lost.
    func checkpoint(persist: Bool) {
        let now = Date()
        if phase == .focus, let runStart {
            FocusLog.shared.addRun(from: runStart, to: min(now, end), persist: persist)
            self.runStart = now
        }
        if phase == .rest, let restMark {
            FocusLog.shared.addRest(from: restMark, to: now, persist: persist)
            self.restMark = now
        }
    }

    /// The system is going to sleep or power off: the session ends here, without a notice. What the focus
    /// or rest accumulated is logged and written, and the app is idle when the machine wakes.
    func endSession() {
        guard phase != .idle else { return }
        if phase == .focus { endFocus() }
        stop()
    }

    func togglePause() {
        guard phase == .focus else { return }
        if let left = pausedLeft {
            let total = end.timeIntervalSince(start)
            end = Date() + left
            start = end - total
            pausedLeft = nil
            runStart = Date()
            arm(left) { [weak self] in self?.focusRanOut() }
            armApproach(left)
        } else {
            if let runStart { FocusLog.shared.addRun(from: runStart, to: Date()) }
            runStart = nil
            timer?.cancel()
            timer = nil
            cancelApproach()
            pausedLeft = max(0, end.timeIntervalSinceNow)
        }
        onChange?()
    }

    /// A rest has no length and shows nothing when it ends: only the menu or the hotkey ends it.
    func beginRest() {
        start = Date()
        end = .distantFuture
        runStart = nil
        restMark = start
        set(.rest)
    }

    func stop() {
        if phase == .rest, let restMark { FocusLog.shared.addRest(from: restMark, to: Date()) }
        restMark = nil
        set(.idle)
    }

    private func run(_ p: Phase, minutes: Double, then done: @escaping () -> Void) {
        let seconds = minutes * 60
        start = Date()
        end = start + seconds
        runStart = start
        restMark = nil
        set(p)
        arm(seconds, then: done)
        if p == .focus { armApproach(seconds) }
    }

    /// One more one-shot, a minute before the end (at once for a focus shorter than that).
    private func armApproach(_ left: TimeInterval) {
        approachTimer?.cancel()
        let ramp = min(Self.approachSeconds, left)
        guard ramp >= 3 else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.approaching = true
                self?.onApproach?(ramp)
            }
        }
        t.schedule(wallDeadline: .now() + (left - ramp), leeway: .milliseconds(200))
        t.resume()
        approachTimer = t
    }

    private func cancelApproach() {
        approachTimer?.cancel()
        approachTimer = nil
        if approaching {
            approaching = false
            onApproachCancel?()
        }
    }

    private func arm(_ seconds: TimeInterval, then done: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { MainActor.assumeIsolated { done() } }
        t.schedule(wallDeadline: .now() + seconds, leeway: .seconds(1))
        t.resume()
        timer = t
    }

    private func set(_ p: Phase) {
        cancelApproach()
        timer?.cancel()
        timer = nil
        pausedLeft = nil
        phase = p
        onChange?()
    }
}
