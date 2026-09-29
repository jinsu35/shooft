// Draws the shooft app icon (a pedal seen from the side, with a ⇧ on it) and
// writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Rounded-square background (macOS icon grid: 824pt square inside 1024 canvas)
    let inset = 100 * s
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.15, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: -90)

    // Pedal: a wedge, thick at the back (right), thin at the front (left).
    ctx.saveGState()
    let pedal = NSBezierPath()
    pedal.move(to: CGPoint(x: 230 * s, y: 380 * s))
    pedal.line(to: CGPoint(x: 780 * s, y: 380 * s))
    pedal.line(to: CGPoint(x: 780 * s, y: 560 * s))
    pedal.line(to: CGPoint(x: 230 * s, y: 470 * s))
    pedal.close()
    NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1).setFill()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    pedal.fill()
    ctx.restoreGState()

    // Front edge of the pedal (darker face)
    let edge = NSBezierPath()
    edge.move(to: CGPoint(x: 230 * s, y: 380 * s))
    edge.line(to: CGPoint(x: 780 * s, y: 380 * s))
    edge.line(to: CGPoint(x: 780 * s, y: 330 * s))
    edge.line(to: CGPoint(x: 230 * s, y: 330 * s))
    edge.close()
    NSColor(calibratedRed: 0.72, green: 0.75, blue: 0.82, alpha: 1).setFill()
    edge.fill()

    // Base plate
    let base = NSBezierPath(roundedRect: CGRect(x: 190 * s, y: 270 * s, width: 644 * s, height: 60 * s),
                            xRadius: 20 * s, yRadius: 20 * s)
    NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.44, alpha: 1).setFill()
    base.fill()

    // Shift arrow, drawn on the pedal's top surface, skewed to match the slope.
    ctx.saveGState()
    ctx.translateBy(x: 505 * s, y: 480 * s)
        let arrow = NSBezierPath()
    let w: CGFloat = 140 * s, stem: CGFloat = 62 * s, h: CGFloat = 190 * s, head: CGFloat = 100 * s
    arrow.move(to: CGPoint(x: 0, y: h / 2))
    arrow.line(to: CGPoint(x: w, y: h / 2 - head))
    arrow.line(to: CGPoint(x: stem, y: h / 2 - head))
    arrow.line(to: CGPoint(x: stem, y: -h / 2))
    arrow.line(to: CGPoint(x: -stem, y: -h / 2))
    arrow.line(to: CGPoint(x: -stem, y: h / 2 - head))
    arrow.line(to: CGPoint(x: -w, y: h / 2 - head))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 26 * s
    NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1).setStroke()
    arrow.stroke()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try png(draw(size: 1024), pixels: px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try png(draw(size: 1024), pixels: 1024).write(to: root.appendingPathComponent("AppIcon-preview.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(root.path)/AppIcon.icns" : "iconutil failed")
