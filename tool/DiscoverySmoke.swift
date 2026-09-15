// Real Bonjour smoke test with two generated peers on this Mac. No remote
// sessions or user data are exchanged. May require macOS local-network access.
import Foundation

@main
struct DiscoverySmoke {
    private enum Failure: Error { case smokeFailed }
    static func main() {
        do { try run() } catch { exit(2) }
    }

    private static func run() throws {
        let first = LocalDiscovery()
        let second = LocalDiscovery()
        let firstID = UUID().uuidString.lowercased()
        let secondID = UUID().uuidString.lowercased()
        var firstSnapshot: [String: Any] = [:]
        var secondSnapshot: [String: Any] = [:]
        first.onChange = { firstSnapshot = $0 }
        second.onChange = { secondSnapshot = $0 }
        defer { first.stop(); second.stop() }
        try first.start(id: firstID, name: "Share Hub Test A")
        try second.start(id: secondID, name: "Share Hub Test B")
        guard wait(until: {
            contains(firstSnapshot, id: secondID, name: "Share Hub Test B") &&
            contains(secondSnapshot, id: firstID, name: "Share Hub Test A")
        }) else { try reportFailure("initial_discovery", firstSnapshot, secondSnapshot); return }
        try second.start(id: secondID, name: "Share Hub Test B Renamed")
        guard wait(until: { contains(firstSnapshot, id: secondID, name: "Share Hub Test B Renamed") }) else {
            try reportFailure("rename", firstSnapshot, secondSnapshot); return
        }
        second.stop()
        guard wait(until: {
            firstSnapshot["state"] as? String == "searching" &&
            !contains(firstSnapshot, id: secondID, name: "Share Hub Test B Renamed")
        }) else { try reportFailure("removal", firstSnapshot, secondSnapshot); return }
        first.stop()
        first.stop()
        second.stop()
        precondition(first.snapshot["state"] as? String == "stopped")
        print("{\"result\":\"passed\",\"scope\":\"two Bonjour peers on one Mac; no trusted sessions\",\"checks\":[\"discovery\",\"rename\",\"removal\",\"repeated_stop\"]}")
    }

    private static func contains(_ snapshot: [String: Any], id: String, name: String) -> Bool {
        (snapshot["devices"] as? [[String: String]] ?? []).contains { $0["id"] == id && $0["name"] == name }
    }

    private static func wait(until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return predicate()
    }

    private static func reportFailure(_ stage: String, _ first: [String: Any], _ second: [String: Any]) throws {
        // Deliberately do not print any discovered device identities or names.
        let result = ["result": "failed", "stage": stage, "firstState": first["state"] as? String ?? "unknown",
                      "secondState": second["state"] as? String ?? "unknown", "scope": "same-Mac Bonjour; timeout may indicate network permission or multicast restrictions"]
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        throw Failure.smokeFailed
    }
}
