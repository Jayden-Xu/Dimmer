import AppKit

/// Shown when a focus or a rest runs out by itself (not when ended by hand): every screen goes
/// dark (over full-screen apps too) with how long it lasted, then fades on its own. It never takes
/// the keyboard; a click fades it right away. Windows exist only while shown.
@MainActor
final class EndScreen {
    private var windows: [EndWindow] = []
    private var generation = 0

    /// `caption`: FOCUSED or RESTED.
    func show(_ caption: String, minutes: Double) {
        dismiss(fade: 0)
        generation += 1
        let shown = generation
        for screen in NSScreen.screens {
            let w = EndWindow(frame: screen.frame) { [weak self] in self?.dismiss() }
            w.contentView?.addSubview(Self.content(caption, minutes: minutes, size: screen.frame.size))
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            for w in windows { w.animator().alphaValue = 1 }
        }
        // One one-shot: fade after a short look.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            MainActor.assumeIsolated { if self?.generation == shown { self?.dismiss() } }
        }
    }

    func dismiss(fade: TimeInterval = 1.0) {
        guard !windows.isEmpty else { return }
        let gone = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade
            for w in gone { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in gone { w.orderOut(nil); w.close() }
            trimMemory()
        })
    }

    /// FOCUSED / 40 MIN, centered. Same look as the menu: SF Mono, uppercase labels with tracking,
    /// text at full strength (white on the dark screen).
    private static func content(_ caption: String, minutes: Double, size: NSSize) -> NSView {
        let top = label(text(caption, size: 14, kern: 4))
        let time = NSMutableAttributedString(attributedString: text(fmt(minutes), size: 120, kern: 2))
        time.addAttribute(.kern, value: 14, range: NSRange(location: time.length - 1, length: 1))  // a mono space is too wide
        time.append(text("MIN", size: 28, kern: 3))
        let bottom = label(time)
        let gap: CGFloat = 4
        let height = top.frame.height + gap + bottom.frame.height
        let column = NSView(frame: NSRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height))
        bottom.frame = NSRect(x: 0, y: 0, width: size.width, height: bottom.frame.height)
        top.frame = NSRect(x: 0, y: bottom.frame.height + gap, width: size.width, height: top.frame.height)
        column.addSubview(top)
        column.addSubview(bottom)
        return column
    }

    /// "40", or "<1" for less than a minute.
    static func fmt(_ m: Double) -> String { m >= 1 ? "\(Int(m.rounded()))" : "<1" }

    private static func text(_ s: String, size: CGFloat, kern: CGFloat) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let t = NSMutableAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
            .paragraphStyle: center,
        ])
        // Tracking between letters only, so the text stays centered.
        t.addAttribute(.kern, value: kern, range: NSRange(location: 0, length: max(0, (s as NSString).length - 1)))
        return t
    }

    private static func label(_ s: NSAttributedString) -> NSTextField {
        let l = NSTextField(labelWithAttributedString: s)
        l.sizeToFit()
        return l
    }
}

/// Non-activating and never key: typing keeps going to the app underneath. A click fades it.
private final class EndWindow: NSPanel {
    private let onClick: () -> Void

    init(frame: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        alphaValue = 0
        colorSpace = .deviceRGB
        backgroundColor = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.94)
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onClick() }
    }
}

/// Hand freed heap pages back to the system. Text and window drawing (the end screen, the menu)
/// leave megabytes of freed-but-dirty malloc pages that would otherwise count until reused.
@MainActor func trimMemory() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
}
