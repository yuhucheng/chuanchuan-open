import AppKit
import XCTest
@testable import ShareHubPlatform

final class ControlClipboardReadStoreTests: XCTestCase {
    func testExactScopeReadsPlainTextAndNotifiesWithoutReadingContent() throws {
        var now: UInt64 = 100
        var changeCount = 0
        var text = "原有文本\n第二行"
        var reads = 0
        let store = ControlClipboardReadStore(
            clock: { now }, sequence: { changeCount }, readText: {
                reads += 1
                return text
            })
        let lease = try store.open(deadlineMicros: 200, epoch: 3,
                                   controllerRevision: 2, targetRevision: 4)
        XCTAssertEqual(lease, 1)
        XCTAssertFalse(store.pollChanged())
        XCTAssertEqual(reads, 0)
        let first = try store.read(lease: lease, epoch: 3,
                                   controllerRevision: 2, targetRevision: 4)
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.text, "原有文本\n第二行")
        changeCount = 1
        text = "新复制"
        XCTAssertTrue(store.pollChanged())
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(store.pollChanged())
        XCTAssertEqual(try store.read(lease: lease, epoch: 3,
                                      controllerRevision: 2, targetRevision: 4).text, "新复制")
        try store.close(lease: lease)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(text, "新复制")
        now = 150
    }

    func testStaleScopeAndExpiryNeverReadSystemText() throws {
        var now: UInt64 = 100
        var reads = 0
        let store = ControlClipboardReadStore(clock: { now }, sequence: { 7 }, readText: {
            reads += 1
            return "敏感内容"
        })
        let lease = try store.open(deadlineMicros: 150, epoch: 1,
                                   controllerRevision: 1, targetRevision: 1)
        XCTAssertThrowsError(try store.read(lease: lease, epoch: 2,
                                            controllerRevision: 1, targetRevision: 1))
        XCTAssertEqual(reads, 0)
        now = 150
        XCTAssertThrowsError(try store.read(lease: lease, epoch: 1,
                                            controllerRevision: 1, targetRevision: 1))
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(reads, 0)
    }

    func testReadRejectsConcurrentChangeAndInvalidText() throws {
        var changeCount = 1
        var text = "有效"
        let store = ControlClipboardReadStore(clock: { 100 }, sequence: { changeCount }, readText: {
            defer { changeCount += 1 }
            return text
        })
        let lease = try store.open(deadlineMicros: 200, epoch: 1,
                                   controllerRevision: 1, targetRevision: 1)
        XCTAssertThrowsError(try store.read(lease: lease, epoch: 1,
                                            controllerRevision: 1, targetRevision: 1))
        try store.close(lease: lease)

        changeCount = 1
        text = "\0"
        let invalid = ControlClipboardReadStore(clock: { 100 }, sequence: { changeCount },
                                                readText: { text })
        let next = try invalid.open(deadlineMicros: 200, epoch: 1,
                                    controllerRevision: 1, targetRevision: 1)
        XCTAssertThrowsError(try invalid.read(lease: next, epoch: 1,
                                              controllerRevision: 1, targetRevision: 1))
    }

    func testSequenceRollbackRetiresLeaseInsteadOfPublishingOldContent() throws {
        var changeCount = 9
        let store = ControlClipboardReadStore(clock: { 100 }, sequence: { changeCount },
                                              readText: { "旧内容" })
        _ = try store.open(deadlineMicros: 200, epoch: 1,
                           controllerRevision: 1, targetRevision: 1)
        changeCount = 8
        XCTAssertFalse(store.pollChanged())
        XCTAssertFalse(store.isActive)
    }

    func testConditionalWriteKeepsNewerLocalTextAndRejectsOldScope() throws {
        var changeCount = 4
        var text = "原有文本"
        var writes = 0
        let store = ControlClipboardReadStore(clock: { 100 }, sequence: { changeCount },
                                              readText: { text }, writeText: { incoming in
            writes += 1
            text = incoming
            changeCount += 1
            return true
        })
        let lease = try store.open(deadlineMicros: 200, epoch: 2,
                                   controllerRevision: 3, targetRevision: 5)
        XCTAssertThrowsError(try store.write(lease: lease, epoch: 1,
                                              controllerRevision: 3, targetRevision: 5,
                                              expectedSequence: 5, text: "越权"))
        XCTAssertEqual(writes, 0)

        changeCount += 1
        text = "本机新复制"
        let conflict = try store.write(lease: lease, epoch: 2,
                                       controllerRevision: 3, targetRevision: 5,
                                       expectedSequence: 5, text: "迟到远端文本")
        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertNil(conflict.sequence)
        XCTAssertEqual(text, "本机新复制")
        XCTAssertEqual(writes, 0)

        let written = try store.write(lease: lease, epoch: 2,
                                      controllerRevision: 3, targetRevision: 5,
                                      expectedSequence: 6, text: "中文\n第二行")
        XCTAssertEqual(written.status, .written)
        XCTAssertEqual(written.sequence, 7)
        XCTAssertEqual(text, "中文\n第二行")
        try store.close(lease: lease)
        XCTAssertEqual(text, "中文\n第二行")
    }

    func testFailedWriteRetiresScopeAndNeverRetriesAnUncertainSystemEffect() throws {
        var changeCount = 1
        var attempts = 0
        let store = ControlClipboardReadStore(clock: { 100 }, sequence: { changeCount },
                                              readText: { "保留" }, writeText: { _ in
            attempts += 1
            changeCount += 1
            return false
        })
        let lease = try store.open(deadlineMicros: 200, epoch: 1,
                                   controllerRevision: 1, targetRevision: 1)
        let result = try store.write(lease: lease, epoch: 1,
                                     controllerRevision: 1, targetRevision: 1,
                                     expectedSequence: 2, text: "远端文本")
        XCTAssertEqual(result.status, .unknown)
        XCTAssertNil(result.sequence)
        XCTAssertFalse(store.isActive)
        XCTAssertThrowsError(try store.write(lease: lease, epoch: 1,
                                              controllerRevision: 1, targetRevision: 1,
                                              expectedSequence: 3, text: "重试"))
        XCTAssertEqual(attempts, 1)
    }

    func testExpiredWriteDoesNotTouchPasteboard() throws {
        var now: UInt64 = 100
        var writes = 0
        let store = ControlClipboardReadStore(clock: { now }, sequence: { 1 },
                                              readText: { "保留" }, writeText: { _ in
            writes += 1
            return true
        })
        let lease = try store.open(deadlineMicros: 150, epoch: 1,
                                   controllerRevision: 1, targetRevision: 1)
        now = 150
        XCTAssertThrowsError(try store.write(lease: lease, epoch: 1,
                                              controllerRevision: 1, targetRevision: 1,
                                              expectedSequence: 2, text: "迟到"))
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(store.isActive)
    }

    func testRealAppKitPasteboardSequenceAndMultilineTextWithoutTouchingUserClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("基线", forType: .string))
        let store = ControlClipboardReadStore(
            clock: { 100 }, sequence: { pasteboard.changeCount },
            readText: { pasteboard.string(forType: .string) },
            writeText: { incoming in
                pasteboard.clearContents()
                return pasteboard.setString(incoming, forType: .string)
            })
        let lease = try store.open(deadlineMicros: 200, epoch: 1,
                                   controllerRevision: 1, targetRevision: 1)
        let before = try store.read(lease: lease, epoch: 1,
                                    controllerRevision: 1, targetRevision: 1)
        let after = try store.write(lease: lease, epoch: 1,
                                    controllerRevision: 1, targetRevision: 1,
                                    expectedSequence: before.sequence, text: "中文\n第二行")
        XCTAssertEqual(after.status, .written)
        XCTAssertTrue((after.sequence ?? 0) > before.sequence)
        XCTAssertEqual(try store.read(lease: lease, epoch: 1,
                                      controllerRevision: 1, targetRevision: 1).text,
                       "中文\n第二行")
        try store.close(lease: lease)
        XCTAssertEqual(pasteboard.string(forType: .string), "中文\n第二行")
    }
}
