import XCTest
@testable import ShareHubPlatform

final class PlatformServicesTests: XCTestCase {
    func testPreferencesPersistAndRejectInvalidNames() throws {
        let suite = "dev.sharehub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DevicePreferences(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: first.discoveryID))
        XCTAssertEqual(first.name, "我的 Mac")
        try first.setName("  书房 Mac  ")
        let restored = DevicePreferences(defaults: defaults)
        XCTAssertEqual(restored.discoveryID, first.discoveryID)
        XCTAssertEqual(restored.name, "书房 Mac")
        for name in ["  ", "hello\nworld", String(repeating: "中", count: 43)] {
            XCTAssertThrowsError(try restored.setName(name))
            XCTAssertEqual(restored.name, "书房 Mac")
        }
    }

    func testCorruptDiscoveryIDIsReplaced() {
        let suite = "dev.sharehub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "discoveryID")
        XCTAssertNotNil(UUID(uuidString: DevicePreferences(defaults: defaults).discoveryID))
    }

    func testDiscoveryRejectsSelfUnsupportedAndMalformedRecords() {
        let localID = UUID().uuidString.lowercased()
        let remoteID = UUID().uuidString.lowercased()
        let record = ["v": "1", "id": remoteID, "name": "书房", "platform": "macos"]
        XCTAssertEqual(DiscoveredDevice(record: record, localID: localID)?.id, remoteID)
        XCTAssertNil(DiscoveredDevice(record: record, localID: remoteID.uppercased()))
        for (key, value) in [("v", "2"), ("id", "bad"), ("name", ""), ("name", "\n"),
                             ("name", String(repeating: "a", count: 129)), ("platform", "unknown")] {
            var changed = record
            changed[key] = value
            XCTAssertNil(DiscoveredDevice(record: changed, localID: localID), "Rejected \(key)")
        }
    }

    func testStopIsIdempotentWithoutStartingNetwork() {
        let discovery = LocalDiscovery()
        discovery.stop()
        discovery.stop()
        XCTAssertEqual(discovery.snapshot["state"] as? String, "stopped")
        XCTAssertEqual((discovery.snapshot["devices"] as? [[String: String]])?.count, 0)
    }
    func testConnectionEndpointIsOptionalAndMalformedPortIsNotOffered() {
        let localID = UUID().uuidString
        var record = ["v": "1", "id": UUID().uuidString, "name": "同名 Mac", "platform": "macos",
                      "host": "test.local", "port": "12345", "key": String(repeating: "a", count: 44)]
        XCTAssertEqual(DiscoveredDevice(record: record, localID: localID)?.dictionary["port"], "12345")
        record["port"] = "65536"
        XCTAssertNil(DiscoveredDevice(record: record, localID: localID)?.dictionary["port"])
        XCTAssertNotNil(DiscoveredDevice(record: record, localID: localID))
    }

    func testContinuousClockDoesNotGoBackwards() {
        let first = ConnectionSecurity.continuousMicros
        let second = ConnectionSecurity.continuousMicros
        XCTAssertGreaterThanOrEqual(second, first)
    }

}
