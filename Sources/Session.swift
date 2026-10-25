import Foundation

/// idle → focus → due → rest → idle.
///
/// `due`: the focus is over (ran out, or ended early) and the break screen waits for
/// "begin rest"; the rest counts from that click. The only timer is one wall-clock one-shot at
/// the end of a focus or a rest (sleep counts; a deadline passed while asleep fires right on wake).
@MainActor
final class Session {
    enum Phase { case idle, focus, due, rest }

    private(set) var phase = Phase.idle
    private var focusStart = Date.distantPast
    /// Start and end of the running focus or rest.
    private(set) var start = Date.distantPast
    private(set) var end = Date.distantPast
    /// How long the last focus actually ran.
    private(set) var focusedMinutes = 0.0
    private var timer: DispatchSourceTimer?

    var onChange: (() -> Void)?

    func startFocus() {
        focusStart = Date()
        run(.focus, minutes: Settings.shared.focusMinutes) { [weak self] in self?.endFocus() }
    }

    /// Time ran out, or ended early from the menu / hotkey.
    func endFocus() {
        guard phase == .focus else { return }
        focusedMinutes = min(Date().timeIntervalSince(focusStart), end.timeIntervalSince(focusStart)) / 60
        set(.due)
    }

    func beginRest() {
        run(.rest, minutes: Settings.shared.restMinutes) { [weak self] in self?.stop() }
    }

    func stop() { set(.idle) }

    private func run(_ p: Phase, minutes: Double, then done: @escaping () -> Void) {
        let seconds = minutes * 60
        start = Date()
        end = start + seconds
        set(p)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { MainActor.assumeIsolated { done() } }
        t.schedule(wallDeadline: .now() + seconds, leeway: .seconds(1))
        t.resume()
        timer = t
    }

    private func set(_ p: Phase) {
        timer?.cancel()
        timer = nil
        phase = p
        onChange?()
    }
}
