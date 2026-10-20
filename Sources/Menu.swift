import AppKit
import ServiceManagement

/// A label + NSSlider embedded in a menu item; changes apply live while dragging.
final class SliderItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let title: String
    private let format: (Double) -> String
    var onChange: ((Double) -> Void)?

    init(title: String, value: Double, min: Double, max: Double, format: @escaping (Double) -> String) {
        self.title = title
        self.format = format
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 24, width: 206, height: 17)
        label.stringValue = "\(title)  \(format(value))"
        slider.frame = NSRect(x: 18, y: 4, width: 206, height: 20)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)
        addSubview(label)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        label.stringValue = "\(title)  \(format(slider.doubleValue))"
        onChange?(slider.doubleValue)
    }
}

/// Everything the menu needs from the app.
@MainActor
protocol MenuHost: AnyObject {
    var axTrusted: Bool { get }
    var hotKeyDisplay: HotKey.Combo? { get }
    func toggleEnabled()
    func setDim(_ dim: Double)
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let settings = Settings.shared
    // Sized by the 16 pt icon plus the system's 16 pt padding: 32 pt like most menu bar items.
    // squareLength follows the bar height instead (38 pt on notched screens).
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private weak var host: MenuHost?

    init(host: MenuHost) {
        self.host = host
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Dimmer", action: nil, keyEquivalent: "")) // placeholder until first open
        statusItem.menu = menu
        statusItem.button?.image = Self.icon() // set once, never changed
    }

    /// Static template bitmap, rendered once. Same picture as the app icon: two dimmed windows
    /// behind one bright window.
    private static func icon() -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                   samplesPerPixel: 2, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
        }
        NSColor(deviceWhite: 0, alpha: 0.4).set()
        rect(0.5, 7, 9.5, 8.5, 1.5).fill()
        rect(6, 0.5, 9.5, 8.5, 1.5).fill()
        // Clear a 1 pt gap around the front window so it reads as separate.
        NSGraphicsContext.current?.compositingOperation = .clear
        rect(2.5, 3, 11, 10, 2.5).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor(deviceWhite: 0, alpha: 1).set()
        rect(3.5, 4, 9, 8, 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = true
        img.accessibilityDescription = "Dimmer"
        return img
    }

    // Items are built when the menu opens and dropped when it closes: nothing kept around while idle.
    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menu.removeAllItems()
                self.menu.addItem(NSMenuItem(title: "Dimmer", action: nil, keyEquivalent: ""))
            }
        }
    }

    private func rebuild() {
        guard let host else { return }
        menu.removeAllItems()

        let toggle = item("开启", #selector(toggleEnabled))
        toggle.state = settings.enabled ? .on : .off
        if let c = host.hotKeyDisplay, c.key.count == 1 {
            toggle.keyEquivalent = c.key
            toggle.keyEquivalentModifierMask = c.cocoaModifiers
        }
        menu.addItem(toggle)

        let slider = SliderItemView(title: "压暗程度", value: settings.dim, min: 0.05, max: 0.85) { "\(Int(($0 * 100).rounded()))%" }
        slider.onChange = { [weak self] v in self?.host?.setDim(v) }
        let sliderItem = NSMenuItem()
        sliderItem.view = slider
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        let login = item("开机启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if !host.axTrusted {
            menu.addItem(item("去授权辅助功能…", #selector(openAXSettings)))
        }
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    // MARK: actions

    @objc private func toggleEnabled() { host?.toggleEnabled() }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("Dimmer: login item change failed: \(error)")
        }
        if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openAXSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
