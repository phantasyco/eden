// Renders Eden's app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's macOS icon grid: an 824 pt body centered on a 1024 pt canvas.
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let top = NSColor(srgbRed: 0.33, green: 0.86, blue: 0.55, alpha: 1)
    let bottom = NSColor(srgbRed: 0.02, green: 0.47, blue: 0.36, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.40, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let s = leaf.size
        leaf.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
