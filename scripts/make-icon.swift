// Renders Resources/AppIcon.icns and the README logo docs/logo.png: the app's orange badge with a white video glyph.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 128, 256, 512]
let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(pixels)
    // macOS icon grid: the body is ~80% of the canvas with a continuous-corner radius.
    let body = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let shape = NSBezierPath(roundedRect: body, xRadius: side * 0.18, yRadius: side * 0.18)
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
    shadow.shadowBlurRadius = side * 0.025
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSGradient(starting: NSColor(red: 1.0, green: 0.55, blue: 0.22, alpha: 1),
               ending: NSColor(red: 0.91, green: 0.33, blue: 0.08, alpha: 1))!.draw(in: shape, angle: -90)
    NSShadow().set()

    let config = NSImage.SymbolConfiguration(pointSize: side * 0.36, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let glyphSize = glyph.size
    glyph.draw(in: NSRect(x: (side - glyphSize.width) / 2, y: (side - glyphSize.height) / 2,
                          width: glyphSize.width, height: glyphSize.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(256).write(to: URL(fileURLWithPath: "docs/logo.png"))
print("Wrote Resources/AppIcon.icns and docs/logo.png")
