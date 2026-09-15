// Runs with Command Line Tools when XCTest/SwiftPM require full Xcode.
// Compile together with PlatformServices.swift; never opens network/capture.
import Foundation

@main
struct PlatformSmoke {
    static func main() throws {
        let suite = "dev.sharehub.smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = DevicePreferences(defaults: defaults)
        precondition(UUID(uuidString: original.discoveryID) != nil)
        try original.setName("  书房 Mac  ")
        let restored = DevicePreferences(defaults: defaults)
        precondition(restored.discoveryID == original.discoveryID && restored.name == "书房 Mac")
        for name in [" ", "bad\nname", String(repeating: "中", count: 43)] {
            do { try restored.setName(name); fatalError("Accepted invalid name") }
            catch PlatformFailure.invalidName {}
        }
        precondition(restored.name == "书房 Mac")
        let record = ["v": "1", "id": UUID().uuidString.lowercased(), "name": "客厅", "platform": "macos"]
        precondition(DiscoveredDevice(record: record, localID: restored.discoveryID) != nil)
        precondition(DiscoveredDevice(record: record, localID: record["id"]!.uppercased()) == nil)
        for (key, value) in [("v", "99"), ("id", "invalid"), ("platform", "other"), ("name", ""), ("name", "bad\nname"), ("name", String(repeating: "a", count: 129))] {
            var changed = record
            changed[key] = value
            precondition(DiscoveredDevice(record: changed, localID: restored.discoveryID) == nil)
        }
        let discovery = LocalDiscovery()
        discovery.stop()
        discovery.stop()
        precondition(discovery.snapshot["state"] as? String == "stopped")
        precondition((discovery.snapshot["devices"] as? [[String: String]])?.isEmpty == true)
        print("PLATFORM_SMOKE passed: preferences, discovery record validation, idempotent stop. No network or capture started.")
    }
}
