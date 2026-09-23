import Foundation
import XCTest
@testable import ShareHubPlatform

final class SelectedFileStoreTests: XCTestCase {
    func testReadPassIsolationAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source")
        try Data("abc".utf8).write(to: url)
        let store = SelectedFileStore()
        defer { store.shutdown() }
        let token = try XCTUnwrap(store.add([url]).first).token
        XCTAssertEqual(try store.read(token: token, offset: 0, length: 3), Data("abc".utf8))
        try store.finish(token: token)
        let first = try store.beginReadPass(token: token)
        XCTAssertEqual(try store.readPass(token: token, passId: first, offset: 0, length: 1), Data("a".utf8))
        let second = try store.beginReadPass(token: token)
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try store.readPass(token: token, passId: first, offset: 0, length: 1))
        XCTAssertThrowsError(try store.finishPass(token: token, passId: first))
        XCTAssertThrowsError(try store.read(token: token, offset: 0, length: 1))
        XCTAssertThrowsError(try store.finish(token: token))
        XCTAssertThrowsError(try store.readPass(token: token, passId: "", offset: 0, length: 1))
        XCTAssertThrowsError(try store.readPass(token: token, passId: second, offset: 1, length: 1))
        XCTAssertThrowsError(try store.readPass(token: token, passId: second, offset: 0, length: 262145))
        XCTAssertThrowsError(try store.finishPass(token: token, passId: second))
        XCTAssertEqual(try store.readPass(token: token, passId: second, offset: 0, length: 3), Data("abc".utf8))
        try store.finishPass(token: token, passId: second)
        XCTAssertThrowsError(try store.readPass(token: token, passId: second, offset: 3, length: 1))
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old"))
        try Data("abc".utf8).write(to: url)
        XCTAssertThrowsError(try store.beginReadPass(token: token))
        XCTAssertThrowsError(try store.readPass(token: token, passId: second, offset: 0, length: 1))
        store.release(token: token)
        XCTAssertThrowsError(try store.beginReadPass(token: token))
        XCTAssertThrowsError(try store.readPass(token: token, passId: second, offset: 0, length: 1))
    }

    func testEmptyPassAndChangedSource() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SelectedFileStore()
        let token = try XCTUnwrap(store.add([url]).first).token
        let pass = try store.beginReadPass(token: token)
        try store.finishPass(token: token, passId: pass)
        try Data([1]).write(to: url)
        XCTAssertThrowsError(try store.finishPass(token: token, passId: pass))
        XCTAssertThrowsError(try store.beginReadPass(token: token))
        store.shutdown()
        XCTAssertThrowsError(try store.beginReadPass(token: token))
    }
}
