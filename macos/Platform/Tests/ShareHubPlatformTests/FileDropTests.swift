import AppKit
import XCTest
@testable import ShareHubPlatform

final class FileDropTests: XCTestCase {
    private func board(_ values: [(NSPasteboard.PasteboardType, String)]) -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects(values.map { type, value in
            let item = NSPasteboardItem()
            item.setString(value, forType: type)
            return item
        })
        return pasteboard
    }

    func testNativeFileURLsUseSameStoreAndRejectPathAsToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("中文 空格.txt")
        try Data([1, 2, 3]).write(to: url)
        let pasteboard = board([(.fileURL, url.absoluteString)])
        defer { pasteboard.releaseGlobally() }
        let store = SelectedFileStore()
        let selected = try store.add(NativeFileDrop.urls(from: pasteboard))
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].name, "中文 空格.txt")
        XCTAssertNotEqual(selected[0].token, url.path)
        XCTAssertThrowsError(try store.read(token: url.path, offset: 0, length: 3))
        XCTAssertEqual(try store.read(token: selected[0].token, offset: 0, length: 3), Data([1, 2, 3]))
        try store.finish(token: selected[0].token)
        store.release(token: selected[0].token)
        XCTAssertEqual(store.count, 0)
    }

    func testMixedTextRemoteURLsAndOversizedBatchAreRejectedWhole() throws {
        let local = "file:///tmp/test.txt"
        let inputs: [[(NSPasteboard.PasteboardType, String)]] = [
            [(.string, "/tmp/unauthorized.txt")],
            [(.fileURL, local), (.string, "/tmp/unauthorized.txt")],
            [(.fileURL, "https://example.com/test.txt")],
            [(.fileURL, "file://remote-host/tmp/test.txt")],
            Array(repeating: (.fileURL, local), count: 65),
        ]
        for input in inputs {
            let pasteboard = board(input)
            defer { pasteboard.releaseGlobally() }
            XCTAssertThrowsError(try NativeFileDrop.urls(from: pasteboard))
        }
    }

    func testInvalidDirectoryAndSymlinkRollBackOnlyNewBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("empty")
        let link = root.appendingPathComponent("link")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let store = SelectedFileStore()
        let retained = try store.add([file]).first!
        for bad in [root, link] {
            let pasteboard = board([(.fileURL, file.absoluteString), (.fileURL, bad.absoluteString)])
            defer { pasteboard.releaseGlobally() }
            XCTAssertThrowsError(try store.add(NativeFileDrop.urls(from: pasteboard)))
            XCTAssertEqual(store.count, 1)
        }
        try store.finish(token: retained.token)
        store.shutdown()
        XCTAssertEqual(store.count, 0)
        XCTAssertThrowsError(try store.add([file]))
    }
}
