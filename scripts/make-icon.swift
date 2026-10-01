// Renders the 🔭 app icon into Resources/AppIcon.icns.
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        // Apple grid: 824/1024 body, 100 margin, ~185 corner radius.
        let inset = s * 100 / 1024
        let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 18 / 1024
        shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
        shadow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        path.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.22, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1),
        ])!.draw(in: body, angle: -90)

        // A few stars.
        NSColor.white.withAlphaComponent(0.55).setFill()
        for (x, y, r) in [(0.28, 0.78, 6.0), (0.72, 0.82, 4.0), (0.80, 0.62, 5.0), (0.22, 0.58, 3.5), (0.62, 0.72, 3.0)] {
            let rr = s * CGFloat(r) / 1024
            NSBezierPath(ovalIn: NSRect(x: s * CGFloat(x) - rr, y: s * CGFloat(y) - rr, width: rr * 2, height: rr * 2)).fill()
        }

        let emoji = NSAttributedString(string: "🔭", attributes: [.font: NSFont.systemFont(ofSize: s * 0.52)])
        let e = emoji.size()
        emoji.draw(at: NSPoint(x: (s - e.width) / 2, y: (s - e.height) / 2 - s * 0.02))
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
