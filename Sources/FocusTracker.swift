import AppKit
import ApplicationServices
import os

let log = Logger(subsystem: "com.jayden.dimmer", category: "focus")

/// Listens for focus / window / Space / screen events (no timers, no polling) and keeps each
/// on-screen overlay ordered directly below its screen's bright window: the focused window on the
/// focused screen, the front-most window on every other screen.
///
/// Timing detail that drives the design: when an app is activated, NSWorkspace / AX notify us
/// 50–250 ms *before* the app raises its windows. Ordering the overlay below a window that is
/// still buried would un-dim everything above it, and the overlay would stay buried once the
/// window rises. So after an event we keep the current picture and re-check once per display
/// frame (for at most 0.7 s) until the focused window really is on top, then re-order in one step.
///
/// While inactive (dim off, no session) it does nothing at all: no AX observer, no window-list reads.
@MainActor
final class FocusTracker {
    private let overlays: Overlays
    private(set) var active = false
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private(set) var axTrusted = AXIsProcessTrusted()

    private var axObserver: AXObserver?
    private var axPID: pid_t = 0
    private var axRetries = 0

    private var updatePending = false
    private var rebindPending = false
    private var recheckPending = false
    private var settleScheduled = false
    private var settleUntil: CFAbsoluteTime = 0
    private var lastActivation: CFAbsoluteTime = 0
    private var focusDirty = true
    private var focusedID: CGWindowID?
    private var dragUntil: CFAbsoluteTime = 0
    private var dragScheduled = false

    private static let settleWindow: CFTimeInterval = 0.7
    /// One frame of the fastest screen: checking more often can't put anything on screen sooner.
    /// Each check copies the window list (~0.7 ms), and a Space switch keeps us waiting ~0.3 s.
    private var settleStep = FocusTracker.frameInterval()

    private static func frameInterval() -> TimeInterval {
        1 / Double(max(60, NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60))
    }

    init(overlays: Overlays) {
        self.overlays = overlays
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsUpdate(rebind: true) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsUpdate(recheck: true) }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spacesChanged() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spacesChanged() }
        }
        // Posted when the Accessibility (TCC) list changes; the DB settles shortly after.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refreshTrust() }
            }
        }

        if !axTrusted {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            axTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            overlays.sync()
            appActivated(NSWorkspace.shared.frontmostApplication)
        } else {
            dropAXObserver()
            overlays.hideAll()
        }
    }

    func refreshTrust() {
        let now = AXIsProcessTrusted()
        guard now != axTrusted else { return }
        axTrusted = now
        axPID = 0
        setNeedsUpdate(rebind: true)
    }

    private func appActivated(_ app: NSRunningApplication?) {
        log.debug("event: activated \(app?.localizedName ?? "?", privacy: .public)")
        lastActivation = CFAbsoluteTimeGetCurrent()
        axRetries = 0
        setNeedsUpdate(rebind: true)
    }

    private func spacesChanged() {
        guard active else { return }
        log.debug("event: spaces/screens changed")
        settleStep = Self.frameInterval()
        overlays.sync()
        setNeedsUpdate(recheck: true)
    }

    // MARK: - Coalescing

    /// Many events arrive together (activate + focus + main window changed…): handle them in a
    /// single pass on the next run-loop turn. `event` = a real notification (as opposed to a
    /// settle re-check); it re-reads the focused window and restarts the settle window.
    func setNeedsUpdate(rebind: Bool = false, recheck: Bool = false,
                        event: Bool = true, refocus: Bool = true) {
        guard active else { return }
        if event {
            settleUntil = CFAbsoluteTimeGetCurrent() + Self.settleWindow
            if refocus { focusDirty = true }
        }
        rebindPending = rebindPending || rebind
        if recheck { scheduleRecheck() }
        guard !updatePending else { return }
        updatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePending = false
                if self.rebindPending {
                    self.rebindPending = false
                    self.rebindAXObserver()
                }
                self.update()
            }
        }
    }

    /// Window drags report a move many times a second, yet nothing needs to change until the window
    /// stops (it may then sit on another screen, or fill one): update once, 0.15 s after the last move.
    private func scheduleDragEnd() {
        dragUntil = CFAbsoluteTimeGetCurrent() + 0.15
        guard !dragScheduled else { return }
        dragScheduled = true
        func wait() {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, dragUntil - CFAbsoluteTimeGetCurrent())) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if CFAbsoluteTimeGetCurrent() < self.dragUntil { return wait() }
                    self.dragScheduled = false
                    self.setNeedsUpdate(refocus: false)
                }
            }
        }
        wait()
    }

    /// Re-check once per frame while the focused window has not been raised yet (bounded by settleUntil).
    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settleStep) { [weak self] in
            MainActor.assumeIsolated {
                self?.settleScheduled = false
                self?.setNeedsUpdate(event: false)
            }
        }
    }

    /// One-shot follow-up after structural changes (window closed, app quit, Space changed):
    /// the window list can lag the notification by a close animation. Not a timer, not polling.
    private func scheduleRecheck() {
        guard !recheckPending else { return }
        recheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                self?.recheckPending = false
                self?.setNeedsUpdate(event: false)
            }
        }
    }

    // MARK: - Core logic

    private struct Win {
        let id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect
    }

    /// Visible windows other than ours, front to back. Skips invisible and tiny (1×1 helper) windows.
    /// `rawNormal` is every normal-level window id (ours included, unfiltered) in z-order.
    private func onScreenWindows() -> (wins: [Win], rawNormal: [CGWindowID]) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
        let raw = list.compactMap { d -> CGWindowID? in
            guard d[kCGWindowLayer as String] as? Int == 0, let id = d[kCGWindowNumber as String] as? Int else { return nil }
            return CGWindowID(id)
        }
        return (list.compactMap { d in
            guard let id = d[kCGWindowNumber as String] as? Int,
                  let pid = d[kCGWindowOwnerPID as String] as? Int, pid_t(pid) != selfPID,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  rect.width > 20, rect.height > 20 else { return nil }
            return Win(id: CGWindowID(id), pid: pid_t(pid), layer: layer, bounds: rect)
        }, raw)
    }

    /// True if `overlay` already sits right below `target`, possibly among our other overlays.
    private func isDirectlyBelow(_ overlay: Int, _ target: CGWindowID, _ raw: [CGWindowID]) -> Bool {
        guard let i = raw.firstIndex(of: target) else { return false }
        let ours = Set(overlays.all.map { CGWindowID($0.windowNumber) })
        for id in raw[(i + 1)...] {
            if id == CGWindowID(overlay) { return true }
            if !ours.contains(id) { return false }
        }
        return false
    }

    func update() {
        guard active else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != selfPID else { return }
        let pid = app.processIdentifier
        let now = CFAbsoluteTimeGetCurrent()
        let settling = now < settleUntil

        if focusDirty {
            focusDirty = false
            focusedID = focusedWindowID(pid)
        }

        let (wins, rawNormal) = onScreenWindows()
        let normal = wins.filter { $0.layer == 0 }
        let screens = Dictionary(NSScreen.screens.compactMap { s in s.displayID.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        let display = { (w: Win) in self.displayID(containing: w.bounds, screens) }
        let appNormal = normal.filter { $0.pid == pid }
        let focused = focusedID.flatMap { id in appNormal.first { $0.id == id } }
        let desktopFocused = focused == nil && (focusedID.map(isDesktop) ?? false)

        // The window to keep bright on the focused screen; nil = nothing (desktop, no windows).
        var focus: Win?
        if appNormal.isEmpty {
            if wins.contains(where: { $0.pid == pid }) { return } // only floating panels: leave as is
            // Just activated / launched: its first window may be a moment away. Wait, don't flash.
            if !desktopFocused && settling && now - lastActivation < Self.settleWindow { return scheduleSettle() }
        } else if !desktopFocused {
            let top = focused ?? appNormal[0]
            // "Raised" means no other app's window above it on its own screen. Windows of the same app
            // may be (a full-screen Safari's toolbar is a separate window over its page). The global
            // z-order across screens is not what the user sees: switching Spaces on one screen puts that
            // screen's windows in front of a full-screen window on another screen, which is still the focused one.
            let topDisplay = display(top)
            let above = normal.lazy.filter { display($0) == topDisplay }.prefix { $0.id != top.id }
            if above.allSatisfy({ $0.pid == pid }) {
                focus = top
            } else if settling {
                // Not raised yet: keep the current picture, the window will pop above the overlay by itself.
                if !settleScheduled { log.debug("pending: top \(normal.first?.id ?? 0), want \(top.id)") }
                return scheduleSettle()
            } else if normal.first?.pid == pid {
                // Settle time is over: the app's own window is on top, use that. Otherwise the app was
                // activated without raising anything (e.g. a click on the desktop).
                focus = appNormal[0]
            }
        }

        let focusDisplay = focus.map(display) ?? mouseDisplay(screens)
        var alphas: [(OverlayWindow, CGFloat)] = []

        // Every screen keeps one bright window: the focused one on the focused screen, the front-most
        // one on each other screen. Skip a screen whose bright window covers it (full screen, Split
        // View, borderless game): nothing shows behind it.
        for w in overlays.active {
            guard let screen = screens[w.displayID] else { continue }
            let anchor = w.displayID == focusDisplay ? focus
                : normal.first { display($0) == w.displayID }
            guard let anchor, !covers(anchor.bounds, screen) else {
                alphas.append((w, 0))
                continue
            }
            if !isDirectlyBelow(w.windowNumber, anchor.id, rawNormal) {
                w.order(.below, relativeTo: Int(anchor.id))
            }
            alphas.append((w, 1))
        }
        overlays.setAlpha(alphas)
        log.debug("focus \(focus?.id ?? 0) on display \(focusDisplay ?? 0) (\(app.localizedName ?? "?", privacy: .public))")
    }

    private func displayID(containing rect: CGRect, _ screens: [CGDirectDisplayID: NSScreen]) -> CGDirectDisplayID? {
        var best: (CGDirectDisplayID, CGFloat)?
        for (id, s) in screens {
            let i = rect.intersection(s.cgFrame)
            let area = i.isNull ? 0 : i.width * i.height
            if area > (best?.1 ?? 0) { best = (id, area) }
        }
        return best?.0
    }

    /// The screen under the mouse: where the user just clicked when no window has focus.
    private func mouseDisplay(_ screens: [CGDirectDisplayID: NSScreen]) -> CGDirectDisplayID? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.value.frame, false) }?.key
    }

    /// Window fills the screen, allowing for the menu bar strip (full-screen windows on notched
    /// displays start below it).
    private func covers(_ r: CGRect, _ screen: NSScreen) -> Bool {
        let s = screen.cgFrame
        return r.minX <= s.minX + 2 && r.maxX >= s.maxX - 2 && r.maxY >= s.maxY - 2
            && r.minY <= s.minY + screen.menuBarInset + 2
    }

    /// Finder's desktop window lives below the normal level.
    private func isDesktop(_ id: CGWindowID) -> Bool {
        guard let info = CGWindowListCreateDescriptionFromArray([NSNumber(value: id)] as CFArray) as? [[String: Any]],
              let layer = info.first?[kCGWindowLayer as String] as? Int else { return false }
        return layer < 0
    }

    // MARK: - Accessibility

    private func focusedWindowID(_ pid: pid_t) -> CGWindowID? {
        guard axTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1) // never hang on a busy app
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return Private.windowID(of: value as! AXUIElement)
    }

    private func dropAXObserver() {
        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
        }
        axObserver = nil
        axPID = 0
    }

    private func rebindAXObserver() {
        guard axTrusted else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != selfPID else { return }
        let pid = app.processIdentifier
        guard pid != axPID else { return }
        dropAXObserver()
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ok = false
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification] {
            if AXObserverAddNotification(obs, element, n as CFString, refcon) == .success { ok = true }
        }
        // Window close is reported reliably only on the window element itself.
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for w in windows { AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, refcon) }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        axObserver = obs
        if ok {
            axPID = pid
        } else if axRetries < 6 {
            // App still launching and not answering AX yet: try again shortly (bounded).
            axRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.setNeedsUpdate(rebind: true) }
            }
        }
    }

    fileprivate func axEvent(_ name: String, _ element: AXUIElement) {
        guard active else { return }
        log.debug("event: AX \(name, privacy: .public)")
        if name == kAXWindowCreatedNotification, let obs = axObserver {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(obs, element, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        switch name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            scheduleDragEnd()
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            setNeedsUpdate(recheck: true)
        default:
            setNeedsUpdate()
        }
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { tracker.axEvent(name, element) }
}
