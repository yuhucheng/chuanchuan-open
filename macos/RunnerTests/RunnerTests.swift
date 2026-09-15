import Cocoa
import XCTest

class RunnerTests: XCTestCase {
  func testDevelopmentDiscoveryDeclaration() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.sharehub.client")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String], ["_sharehub-dev._tcp"])
    XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
  }
}
