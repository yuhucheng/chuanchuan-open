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
}
