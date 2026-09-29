// Compiles with the production FileAccessBridge, native store and FlutterMacOS.
// Uses a private pasteboard and generated files; no Finder gesture or capture.
import AppKit
import FlutterMacOS

@main struct FileDropProbe {
    private static let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func wait(_ ready: () -> Bool, seconds: Double = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        require(ready(), "Timed out waiting for native file operation")
    }
    static func call(_ bridge: FileAccessBridge, _ method: String, _ arguments: Any?) -> Any? {
        var done = false
        var response: Any?
        // The inert, never-shown window only satisfies the picker method's API.
        bridge.handle(FlutterMethodCall(methodName: method, arguments: arguments), window: window) {
            response = $0; done = true
        }
        wait { done }
        return response
    }
    static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("drop.txt")
        try Data([1, 2, 3]).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let bridge = FileAccessBridge()
        var batch: [[String: Any]]?
        var acknowledge: ((Bool) -> Void)?
        bridge.sendDrop = { files, ack in batch = files; acknowledge = ack }
        func offer() -> String {
            batch = nil; acknowledge = nil
            require(bridge.acceptDrop(board), "Native drop refused")
            wait { batch != nil }
            require(Set(batch!.first!.keys) == ["token", "name", "size"], "Unexpected capability fields")
            return batch!.first!["token"] as! String
        }
        func read(_ token: String) -> Any? {
            call(bridge, "files.read", ["token": token, "offset": Int64(0), "length": 3])
        }

        let accepted = offer()
        acknowledge?(true)
        acknowledge?(false) // A duplicate reply cannot revoke transferred ownership.
        require((read(accepted) as? FlutterStandardTypedData)?.data == Data([1, 2, 3]), "Accepted capability lost")
        require(call(bridge, "files.finish", accepted) == nil, "Final check failed")
        _ = call(bridge, "files.release", accepted)
        require(read(accepted) is FlutterError, "Released capability remained readable")
        require(read(file.path) is FlutterError, "Arbitrary path authorized")

        let refused = offer()
        acknowledge?(false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        require(read(refused) is FlutterError, "Unaccepted capability leaked")

        let expired = offer()
        RunLoop.current.run(until: Date().addingTimeInterval(10.2))
        acknowledge?(true) // A late acknowledgement cannot restore the token.
        require(read(expired) is FlutterError, "Timed-out capability restored")

        batch = nil
        require(bridge.acceptDrop(board), "Final drop refused")
        bridge.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        require(batch == nil, "Delivery escaped shutdown")
        require(!bridge.acceptDrop(board), "Closed bridge accepted files")
        print("Native file drop bridge: accepted, rejected, timeout, duplicate/late ack, arbitrary path and shutdown passed")
    }
}
