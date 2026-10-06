// Draws the app icon (dark card, script lines, one highlighted word) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let card = NSRect(x: 100, y: 100, width: 824, height: 824)
NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
           ending: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.08, alpha: 1))!
    .draw(in: NSBezierPath(roundedRect: card, xRadius: 185, yRadius: 185), angle: -90)
// Script lines: read (dim), current (with a highlighted word), upcoming (bright).
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: NSColor) {
    c.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 58), xRadius: 29, yRadius: 29).fill()
}
let dim = NSColor.white.withAlphaComponent(0.28), bright = NSColor.white.withAlphaComponent(0.92)
let gold = NSColor(srgbRed: 1, green: 0.8, blue: 0.25, alpha: 1)
bar(220, 700, 470, dim); bar(720, 700, 90, dim)
bar(220, 590, 250, dim); bar(500, 590, 200, gold); bar(730, 590, 80, bright)
bar(220, 480, 590, bright)
bar(220, 370, 400, bright)
// Waveform
gold.withAlphaComponent(0.9).setFill()
for (i, h) in [60.0, 120, 180, 110, 70, 140, 90].enumerated() {
    let x = 260 + CGFloat(i) * 70
    NSBezierPath(roundedRect: NSRect(x: x, y: 240 - h / 2, width: 34, height: h), xRadius: 17, yRadius: 17).fill()
}
image.unlockFocus()

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
