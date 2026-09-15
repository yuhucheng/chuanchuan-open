// Draw the code-native Share Hub mark for the macOS asset catalog.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    NSColor(calibratedRed: 0.094, green: 0.235, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 200, yRadius: 200).fill()
    let center = NSPoint(x: 512, y: 512)
    let nodes = [NSPoint(x: 512, y: 735), NSPoint(x: 305, y: 390), NSPoint(x: 719, y: 390)]
    NSColor(calibratedRed: 0.76, green: 0.93, blue: 0.83, alpha: 1).setStroke()
    for node in nodes {
        let path = NSBezierPath()
        path.move(to: center)
        path.line(to: node)
        path.lineWidth = 40
        path.stroke()
    }
    NSColor(calibratedRed: 0.76, green: 0.93, blue: 0.83, alpha: 1).setFill()
    for point in nodes + [center] {
        NSBezierPath(ovalIn: NSRect(x: point.x - 68, y: point.y - 68, width: 136, height: 136)).fill()
    }
    image.unlockFocus()
    let source = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("app_icon_\(pixels).png"))
}
