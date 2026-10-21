// Draws Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// Lime on black like the other IAMJARL Mac apps. The colours are the design system's dark tokens:
// primary #D0FF00, background.app #000000 and border.subtle rgba(255, 255, 255, 0.12).
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    let lime = NSColor(srgbRed: 0xD0 / 255.0, green: 1, blue: 0, alpha: 1)
    NSColor.black.setFill()
    shape.fill()
    // A hairline edge so the black square still reads on a dark Dock.
    NSColor.white.withAlphaComponent(0.12).setStroke()
    shape.lineWidth = max(1, size * 0.006)
    shape.stroke()

    // Timeline: three clips, the main track brightest.
    let bar = rect.width * 0.09
    let alphas: [CGFloat] = [1, 0.6, 0.35]
    let widths: [CGFloat] = [0.62, 0.42, 0.52]
    for (i, w) in widths.enumerated() {
        let y = rect.minY + rect.height * 0.22 + CGFloat(i) * bar * 1.6
        let x = rect.minX + rect.width * (i == 1 ? 0.30 : 0.18)
        lime.withAlphaComponent(alphas[i]).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: rect.width * w, height: bar), xRadius: bar / 2, yRadius: bar / 2).fill()
    }
    // Play triangle
    let t = NSBezierPath()
    let cx = rect.midX, cy = rect.minY + rect.height * 0.68, r = rect.width * 0.17
    t.move(to: NSPoint(x: cx - r * 0.7, y: cy + r))
    t.line(to: NSPoint(x: cx - r * 0.7, y: cy - r))
    t.line(to: NSPoint(x: cx + r, y: cy))
    t.close()
    lime.setFill()
    t.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
