// Draws the app icon (same idea as the menu bar icon: dim screen, one bright window) and writes
// an .iconset folder. build.sh runs it and turns the result into AppIcon.icns with iconutil.
// Usage: swift icon.swift <out.iconset>
import AppKit

func draw(_ ctx: CGContext) {
    // 1024-unit canvas, Big Sur grid: 824×824 rounded square, 100 margin.
    func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
    }
    func fill(_ path: CGPath, top: CGColor, bottom: CGColor, _ box: CGRect) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: rgb, colors: [bottom, top] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
        ctx.restoreGState()
    }

    // Background tile with a soft drop shadow.
    let tile = rrect(100, 100, 824, 824, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(c(0x1B1D22))
    ctx.fillPath()
    ctx.restoreGState()
    fill(tile, top: c(0x3A3F4A), bottom: c(0x15171B), CGRect(x: 100, y: 100, width: 824, height: 824))

    // Two dimmed windows behind.
    ctx.setFillColor(c(0xFFFFFF, 0.13))
    ctx.addPath(rrect(196, 532, 400, 270, 30)); ctx.fillPath()
    ctx.addPath(rrect(428, 222, 400, 270, 30)); ctx.fillPath()

    // The focused window: bright, with a glow.
    let win = CGRect(x: 262, y: 322, width: 500, height: 380)
    let winPath = rrect(win.minX, win.minY, win.width, win.height, 40)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 110, color: c(0xFFF4DE, 0.55))
    ctx.addPath(winPath)
    ctx.setFillColor(c(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    fill(winPath, top: c(0xFFFFFF), bottom: c(0xE8EBF0), win)

    // Title bar line and three dots.
    ctx.setFillColor(c(0xD5DAE2))
    ctx.fill(CGRect(x: win.minX, y: win.maxY - 70, width: win.width, height: 3))
    for i in 0..<3 {
        ctx.addEllipse(in: CGRect(x: win.minX + 34 + CGFloat(i) * 40, y: win.maxY - 50, width: 24, height: 24))
    }
    ctx.setFillColor(c(0xC4CAD3))
    ctx.fillPath()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        let px = base * s
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        draw(ctx)
        let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: out.appendingPathComponent("icon_\(base)x\(base)\(s == 2 ? "@2x" : "").png"))
    }
}
