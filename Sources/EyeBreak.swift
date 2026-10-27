import AppKit

/// 20-20-20: after every 20 minutes at the screen, look 20 feet away for 20 seconds.
///
/// One one-shot timer on the monotonic clock (it stops while the Mac sleeps), re-armed after
/// each reminder. Anything that already rested the eyes restarts the 20 minutes instead:
/// screens asleep, screen locked, switched to another user, a rest running, or 5 minutes
/// without input. Nothing runs in between.
@MainActor
final class EyeBreak {
    let interval: TimeInterval
    private let onDue: () -> Void
    private var timer: DispatchSourceTimer?
    /// When the next reminder is due (for the menu); nil while away.
    private(set) var due: Date?
    /// Why the screen is not being looked at right now; the timer runs only while empty.
    private var away: Set<String> = []
    /// No input for this long counts as a break already taken.
    private static let idleBreak: TimeInterval = 5 * 60

    init(minutes: Double, onDue: @escaping () -> Void) {
        interval = minutes * 60
        self.onDue = onDue

        let ws = NSWorkspace.shared.notificationCenter
        watch(ws, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screens")
        watch(ws, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep")
        watch(ws, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        watch(DistributedNotificationCenter.default(),
              Notification.Name("com.apple.screenIsLocked"), Notification.Name("com.apple.screenIsUnlocked"), "lock")
        arm()
    }

    /// A rest is a break: no reminders during it, and the 20 minutes start over when it ends.
    func setResting(_ resting: Bool) { set("rest", resting) }

    private func watch(_ center: NotificationCenter, _ gone: Notification.Name, _ back: Notification.Name, _ reason: String) {
        center.addObserver(forName: gone, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, true) }
        }
        center.addObserver(forName: back, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(reason, false) }
        }
    }

    private func set(_ reason: String, _ isAway: Bool) {
        let changed = isAway ? away.insert(reason).inserted : away.remove(reason) != nil
        guard changed else { return }
        if away.isEmpty { arm() } else { cancel() }
    }

    private func arm() {
        cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fire() } }
        t.schedule(deadline: .now() + interval, leeway: .seconds(5))
        t.resume()
        timer = t
        // Wall clock is fine here: sleep cancels and re-arms, so the two clocks never drift apart.
        due = Date() + interval
    }

    private func cancel() {
        timer?.cancel()
        timer = nil
        due = nil
    }

    private func fire() {
        arm()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < Self.idleBreak { onDue() }
    }
}
