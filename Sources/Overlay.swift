import AppKit

/// One full-screen, click-through, semi-transparent black window. In per-Space mode it belongs
/// to exactly one desktop Space; in fallback mode it joins all Spaces.
final class OverlayWindow: NSWindow {
    let displayID: CGDirectDisplayID
    /// 0 = joins all Spaces (fallback mode).
    let spaceID: UInt64
    /// An extra layer of black over the dim. Core Animation deepens it through the last minute of a focus
    /// (no timer of ours runs); the window's own alpha stays a plain 0 / 1.
    private let ramp = CALayer()

    init(frame: NSRect, displayID: CGDirectDisplayID, spaceID: UInt64, dim: Double) {
        self.displayID = displayID
        self.spaceID = spaceID
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        // Never .fullScreenAuxiliary. In per-Space mode we also drop .canJoinAllSpaces: on macOS 26 a
        // sticky window still shows up in full-screen Spaces, so each desktop gets its own overlay
        // and full-screen Spaces get none. .transient (not .stationary): Mission Control hides the
        // overlay; with .stationary it stayed in place and covered the window thumbnails.
        collectionBehavior = spaceID == 0 ? [.canJoinAllSpaces, .transient, .ignoresCycle] : [.transient, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        tabbingMode = .disallowed
        alphaValue = 0
        // Device RGB: black needs no colour matching. With the default (the screen's profile) AppKit
        // builds ColorSync transforms per display (~1 MB each) and again after display changes.
        colorSpace = .deviceRGB
        // Window alpha stays 0/1 (visibility); the dim level lives in the background colour.
        backgroundColor = Self.color(dim)
        setFrame(frame, display: false)
        contentView?.wantsLayer = true
        ramp.backgroundColor = NSColor.black.cgColor
        ramp.opacity = 0
        ramp.frame = contentView?.bounds ?? .zero
        ramp.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentView?.layer?.addSublayer(ramp)
    }

    /// Deepen the dim to `extra` (the share of the remaining light taken away) over `seconds`, evenly.
    func startRamp(to extra: Float, over seconds: TimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = ramp.presentation()?.opacity ?? 0
        a.toValue = extra
        a.duration = seconds
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        ramp.opacity = extra
        ramp.add(a, forKey: "ramp")
    }

    func resetRamp(over seconds: TimeInterval) {
        let from = ramp.presentation()?.opacity ?? ramp.opacity
        ramp.removeAllAnimations()
        ramp.opacity = 0
        guard from > 0, seconds > 0 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = 0
        a.duration = seconds
        ramp.add(a, forKey: "reset")
    }

    static func color(_ dim: Double) -> NSColor { NSColor(deviceRed: 0, green: 0, blue: 0, alpha: dim) }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the overlay windows: one per (display, desktop Space), created when that Space is first shown.
@MainActor
final class Overlays {
    private(set) var all: [OverlayWindow] = []
    /// The overlays on screen right now (each display's current Space, if it is a desktop).
    private(set) var active: [OverlayWindow] = []
    let perSpace = Private.spacesAvailable

    private var dim = 0.35

    init() {
        log.info("spaces: \(self.perSpace ? "per-Space" : "sticky", privacy: .public)")
    }

    /// Bring the window set in line with the current displays and Spaces. Cheap; call on any
    /// Space / screen change.
    func sync() {
        let screens = NSScreen.screens.compactMap { s in s.displayID.map { (id: $0, screen: s) } }
        var wanted: [(display: CGDirectDisplayID, space: UInt64, frame: NSRect)] = []
        var liveSpaces = Set<UInt64>()
        var allSpaces: [UInt64] = []

        if perSpace {
            guard let info = Private.displaySpaces() else { return } // transient failure: keep what we have
            for entry in info {
                allSpaces += entry.all
                liveSpaces.formUnion(entry.desktops)
                guard entry.currentIsDesktop else { continue } // full-screen / Split View: no overlay
                let matching = screens.filter { $0.screen.uuidString == entry.display }
                let targets = (entry.display == "Main" || (matching.isEmpty && info.count == 1)) ? screens : matching
                for t in targets { wanted.append((t.id, entry.current, t.screen.frame)) }
            }
        } else {
            for t in screens { wanted.append((t.id, 0, t.screen.frame)) }
        }

        let liveDisplays = Set(screens.map(\.id))
        var keep: [OverlayWindow] = []
        for w in all {
            let alive = liveDisplays.contains(w.displayID) && (w.spaceID == 0 ? !perSpace : liveSpaces.contains(w.spaceID))
            if alive { keep.append(w) } else { w.alphaValue = 0; w.orderOut(nil); w.close() }
        }
        all = keep

        var nowActive: [OverlayWindow] = []
        for want in wanted {
            if let w = all.first(where: { $0.displayID == want.display && $0.spaceID == want.space }) {
                if w.frame != want.frame { w.setFrame(want.frame, display: false) }
                if want.space != 0, Private.spaces(ofWindow: w.windowNumber) != [want.space] {
                    Private.assign(window: w.windowNumber, to: want.space, removingFrom: allSpaces)
                }
                nowActive.append(w)
            } else {
                let w = OverlayWindow(frame: want.frame, displayID: want.display, spaceID: want.space, dim: dim)
                w.orderFrontRegardless() // alpha 0: invisible until the tracker orders and shows it
                if want.space != 0 { Private.assign(window: w.windowNumber, to: want.space, removingFrom: allSpaces) }
                all.append(w)
                nowActive.append(w)
                log.debug("created overlay \(w.windowNumber) display \(want.display) space \(want.space)")
            }
        }
        active = nowActive
    }

    /// The last minute of a focus: deepen the dim over `seconds`, by a third more (never past 70%).
    func startRamp(over seconds: TimeInterval) {
        guard dim > 0 else { return }
        let target = min(0.7, dim + 0.33)
        guard target > dim + 0.02 else { return }
        let extra = Float((target - dim) / (1 - dim))
        for w in all { w.startRamp(to: extra, over: seconds) }
    }

    /// Back to the chosen dim (the approach was abandoned, or the end-of-focus notice is over).
    func resetRamp(over seconds: TimeInterval = 0.6) {
        for w in all { w.resetRamp(over: seconds) }
    }

    func setDim(_ dim: Double) {
        guard dim != self.dim else { return }
        resetRamp(over: 0)
        self.dim = dim
        let color = OverlayWindow.color(dim)
        for w in all { w.backgroundColor = color }
        if dim == 0 { hideAll() }
    }

    /// Instantly set each window's alpha (0 = hidden, 1 = shown). Never orderOut: re-ordering in can flash.
    /// At dim 0 everything stays hidden: a clear window would still be composited.
    func setAlpha(_ changes: [(OverlayWindow, CGFloat)]) {
        for (w, a) in changes {
            let a = dim > 0 ? a : 0
            if w.alphaValue != a { w.alphaValue = a }
        }
    }

    /// Hide every overlay, including other Spaces' (effect turned off).
    func hideAll() {
        setAlpha(all.map { ($0, 0) })
    }
}
