// Draws the Mailroom Classic app icon (white envelope on a blue rounded square)
// at every size macOS needs, and writes them as PNG files. Run from the repo root:
//   swift scripts/make-icon.swift MailroomClassic/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputFolder = URL(fileURLWithPath: CommandLine.arguments[1])

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's icon grid: the shape fills ~80% of the canvas, with rounded corners.
    let inset = size * 0.1
    let shapeRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: shapeRect, xRadius: shapeRect.width * 0.225, yRadius: shapeRect.width * 0.225)

    // Soft drop shadow under the shape.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Classic Outlook-ish blue gradient, lighter at the top.
    let gradient = NSGradient(starting: NSColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1),
                              ending: NSColor(red: 0.04, green: 0.27, blue: 0.62, alpha: 1))!
    gradient.draw(in: shape, angle: -90)

    // White envelope symbol in the middle.
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let envelope = NSImage(systemSymbolName: "envelope.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let envelopeSize = envelope.size
        let origin = NSPoint(x: (size - envelopeSize.width) / 2, y: (size - envelopeSize.height) / 2)
        envelope.draw(in: NSRect(origin: origin, size: envelopeSize))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Every size the macOS asset catalog asks for (points × scale = pixels).
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! drawIcon(pixels: points * scale).write(to: outputFolder.appendingPathComponent(name))
    print("wrote \(name)")
}
