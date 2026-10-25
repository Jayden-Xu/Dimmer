import AppKit

/// Shown when a focus ends: every screen goes dark (over full-screen apps too) and waits. The
/// screen under the mouse says how long you focused and offers "begin rest"; that button is the
/// only way out, and 3 s after it the screen fades. Windows exist only while shown.
@MainActor
final class BreakScreen {
    private var windows: [BreakWindow] = []
    private var leaving = false

    /// "begin rest" pressed; returns when the rest ends.
    var onBegin: (() -> Date)?

    func show(focused minutes: Double) {
        guard windows.isEmpty else { return }
        leaving = false
        let mouse = NSEvent.mouseLocation
        let main = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        for screen in NSScreen.screens {
            let w = BreakWindow(frame: screen.frame)
            if screen == main {
                let (view, button) = Self.content(focused: minutes, size: screen.frame.size) { [weak self] in self?.begin() }
                w.contentView?.addSubview(view)
                w.button = button
                w.makeKeyAndOrderFront(nil) // swallow typing meant for the window you can no longer see
            } else {
                w.orderFrontRegardless()
            }
            windows.append(w)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            for w in windows { w.animator().alphaValue = 1 }
        }
    }

    func begin() {
        guard !windows.isEmpty, !leaving else { return }
        leaving = true
        let back = onBegin?().formatted(date: .omitted, time: .shortened) ?? ""
        for w in windows { w.button?.title = "BACK AT \(back.uppercased())" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        guard !windows.isEmpty else { return }
        let gone = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            for w in gone { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in gone { w.orderOut(nil); w.close() }
            trimMemory()
        })
    }

    /// FOCUSED / 40 MIN / [BEGIN REST], centered on a screen of `size`.
    static func content(focused minutes: Double, size: NSSize, action: @escaping () -> Void) -> (NSView, PillButton) {
        let caption = label(text("FOCUSED", size: 15, weight: .bold, alpha: 0.45, kern: 3.5))
        let time = NSMutableAttributedString(attributedString: text(fmt(minutes), size: 132, weight: .semibold, alpha: 0.95, kern: 1))
        time.append(text(" MIN", size: 34, weight: .bold, alpha: 0.5, kern: 2))
        let button = PillButton(title: "BEGIN REST", action: action)
        return (stack([caption, label(time), button], gaps: [0, 40], in: size), button)
    }

    static func fmt(_ m: Double) -> String { m >= 1 ? "\(Int(m.rounded()))" : "<1" }
    /// SF Pro Rounded: softer than the default face at display sizes.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        return f.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? f
    }

    static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, kern: CGFloat) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let t = NSMutableAttributedString(string: s, attributes: [
            .font: rounded(size, weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
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

    /// Centers the views in a column in the middle of the screen; `gaps[i]` follows `views[i]`.
    private static func stack(_ views: [NSView], gaps: [CGFloat], in size: NSSize) -> NSView {
        let height = views.reduce(0) { $0 + $1.frame.height } + gaps.reduce(0, +)
        let column = NSView(frame: NSRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height))
        var y = height
        for (i, v) in views.enumerated() {
            y -= v.frame.height
            let w = v is NSTextField ? size.width : v.frame.width
            v.frame = NSRect(x: (size.width - w) / 2, y: y, width: w, height: v.frame.height)
            column.addSubview(v)
            if i < gaps.count { y -= gaps[i] }
        }
        return column
    }
}

/// A soft, translucent capsule with rounded uppercase text. Hover brightens it, pressing dims it;
/// the click counts on release inside. Each change is one layer colour change that the system
/// animates: nothing runs while the pointer stays still.
final class PillButton: NSView {
    private let action: () -> Void
    var title: String { didSet { needsDisplay = true } }
    private var hovered = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }

    init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        wantsLayer = true
        layer?.cornerRadius = 30
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let alpha: CGFloat = pressed ? 0.08 : hovered ? 0.24 : 0.14
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = pressed ? 0.06 : 0.18
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = BreakScreen.text(title, size: 16, weight: .bold, alpha: 0.9, kern: 2)
        let size = s.size()
        s.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Non-activating panel: it can take the keyboard (and swallow it) without activating dimmer.
private final class BreakWindow: NSPanel {
    var button: PillButton?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        becomesKeyOnlyIfNeeded = false
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

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {} // no way out but the button, and no beep
    override func cancelOperation(_ sender: Any?) {}
}

/// Hand freed heap pages back to the system. Text and window drawing (the break screen, the menu)
/// leave megabytes of freed-but-dirty malloc pages that would otherwise count until reused.
@MainActor func trimMemory() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
}
