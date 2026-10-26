import AppKit

/// Shown when a focus ends: a small card in the top-right corner of the screen under the mouse,
/// where notifications appear. It only tells you; it takes no keyboard and blocks nothing. Rest
/// starts like a focus does, from the menu or the hotkey; that, or a click on the card, puts it
/// away. The window exists only while shown.
@MainActor
final class Reminder {
    private var panel: NSPanel?

    func show(focused minutes: Double) {
        guard panel == nil else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = NSSize(width: 240, height: 54)
        let area = screen.visibleFrame // below the menu bar
        let p = ReminderPanel(frame: NSRect(x: area.maxX - size.width - 12, y: area.maxY - size.height - 12,
                                            width: size.width, height: size.height))
        p.contentView?.addSubview(ReminderView(minutes: minutes, frame: NSRect(origin: .zero, size: size)) { [weak self] in
            self?.dismiss()
        })
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func dismiss() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.close()
            trimMemory()
        })
    }

    /// "40", or "<1" for a focus ended within its first minute.
    static func fmt(_ m: Double) -> String { m >= 1 ? "\(Int(m.rounded()))" : "<1" }
}

/// FOCUSED  40 MIN over the bar, laid out like the menu's countdown; a click puts it away.
private final class ReminderView: NSView {
    private let minutes: Double
    private let onClick: () -> Void

    init(minutes: Double, frame: NSRect, onClick: @escaping () -> Void) {
        self.minutes = minutes
        self.onClick = onClick
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        Ink.readout(caption: "FOCUSED", value: Ink.minutes(Reminder.fmt(minutes)),
                    fraction: minutes / Settings.shared.focusMinutes, in: bounds, inset: 16)
    }
}

/// Borderless, non-activating, never key: showing it doesn't take focus from the app you're in.
/// Menu material and corners, above full-screen apps too.
private final class ReminderPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        alphaValue = 0
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        contentView = bg
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hand freed heap pages back to the system. Text and window drawing (the reminder, the menu)
/// leave megabytes of freed-but-dirty malloc pages that would otherwise count until reused.
@MainActor func trimMemory() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { malloc_zone_pressure_relief(nil, 0) }
}
