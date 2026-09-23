import Cocoa
import XCTest

class RunnerTests: XCTestCase {
  func testDevelopmentDiscoveryDeclaration() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.sharehub.client")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String], ["_sharehub-dev._tcp"])
    XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
  }

  func testBrandTrayAssetLoadsAsTemplateAtNativeScales() throws {
    let image = try XCTUnwrap(NSImage(named: NSImage.Name("TrayIcon")))
    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    for pixels in [16, 32] {
      let bitmap = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
      image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
      NSGraphicsContext.restoreGraphicsState()
      let alphas = (0..<pixels).flatMap { y in
        (0..<pixels).map { x in bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
      }
      XCTAssertTrue(alphas.contains { $0 > 0.5 }, "Tray mark must not be empty")
      XCTAssertTrue(alphas.contains { $0 == 0 }, "Tray background must remain transparent")
    }
  }
}
