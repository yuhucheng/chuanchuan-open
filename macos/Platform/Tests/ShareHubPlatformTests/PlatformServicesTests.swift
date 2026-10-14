import XCTest
@testable import ShareHubPlatform

final class PlatformServicesTests: XCTestCase {
    func testPreferencesPersistAndRejectInvalidNames() throws {
        let suite = "dev.sharehub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DevicePreferences(defaults: defaults, computerName: "  办公室 Mac  ")
        XCTAssertNotNil(UUID(uuidString: first.discoveryID))
        XCTAssertEqual(first.name, "办公室 Mac")
        try first.setName("  书房 Mac  ")
        let restored = DevicePreferences(defaults: defaults)
        XCTAssertEqual(restored.discoveryID, first.discoveryID)
        XCTAssertEqual(restored.name, "书房 Mac")
        for name in ["  ", "hello\nworld", String(repeating: "中", count: 43)] {
            XCTAssertThrowsError(try restored.setName(name))
            XCTAssertEqual(restored.name, "书房 Mac")
        }
    }

    func testLegacyDefaultMigratesWithoutChangingDiscoveryIDOrCustomName() throws {
        let suite = "dev.sharehub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: "discoveryID")
        defaults.set("我的 Mac", forKey: "deviceName")
        let device = DevicePreferences(defaults: defaults, computerName: "办公室电脑")
        XCTAssertEqual(device.name, "办公室电脑")
        XCTAssertEqual(device.discoveryID, id)
        try device.setName("书房电脑")
        XCTAssertEqual(DevicePreferences(defaults: defaults, computerName: "新系统名").name, "书房电脑")
        try device.setName("我的 Mac")
        XCTAssertEqual(DevicePreferences(defaults: defaults, computerName: "新系统名").name, "我的 Mac")
    }

    func testInvalidSystemNameFallsBackToValidPlatformName() {
        let suite = "dev.sharehub.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for invalid in [nil, "   ", "bad\nname", String(repeating: "中", count: 43)] as [String?] {
            defaults.removeObject(forKey: "deviceName")
            XCTAssertEqual(DevicePreferences(defaults: defaults, computerName: invalid).name, "Mac")
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
