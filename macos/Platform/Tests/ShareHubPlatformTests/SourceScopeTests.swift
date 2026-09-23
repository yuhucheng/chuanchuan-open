import Darwin
import Foundation
import XCTest
@testable import ShareHubPlatform

final class SourceScopeTests: XCTestCase {
    func testLocalPreparationThenGuardedPassPermanentlyRejectsAllLegacyPaths() throws {
        let fixture = try SourceFixture()
        defer { fixture.close() }
        let token = fixture.token
        XCTAssertEqual(try fixture.store.read(token: token, offset: 0, length: 3), Data("abc".utf8))
        try fixture.store.finish(token: token)
        let legacy = try fixture.store.beginReadPass(token: token)
        let scope = try fixture.scope()
        XCTAssertThrowsError(try fixture.store.read(token: token, offset: 0, length: 1))
        XCTAssertThrowsError(try fixture.store.finish(token: token))
        XCTAssertThrowsError(try fixture.store.beginReadPass(token: token))
        XCTAssertThrowsError(try fixture.store.readPass(token: token, passId: legacy, offset: 0, length: 1))
        XCTAssertThrowsError(try fixture.store.finishPass(token: token, passId: legacy))
        let pass = try fixture.store.beginPass(token: token, scope: scope)
        expect(.invalidRead) { try fixture.store.readPass(token: token, scope: scope, passId: pass, offset: 1, length: 1) }
        expect(.invalidRead) { try fixture.store.readPass(token: token, scope: scope, passId: pass, offset: 0, length: 262_145) }
        XCTAssertEqual(try fixture.store.readPass(token: token, scope: scope, passId: pass, offset: 0, length: 1), Data("a".utf8))
        expect(.sourceIncomplete) { try fixture.store.finishPass(token: token, scope: scope, passId: pass) }
        XCTAssertEqual(try fixture.store.readPass(token: token, scope: scope, passId: pass, offset: 1, length: 2), Data("bc".utf8))
        try fixture.store.finishPass(token: token, scope: scope, passId: pass)
        expect(.invalidRead) { try fixture.store.readPass(token: token, scope: scope, passId: pass, offset: 3, length: 1) }
    }

    func testPauseRebindKeepsOriginalBindingAndOldScopeCannotCancelReplacement() throws {
        let fixture = try SourceFixture()
        defer { fixture.close() }
        let first = try fixture.scope()
        let oldPass = try fixture.store.beginPass(token: fixture.token, scope: first)
        expect(.invalidScope) { try fixture.scope() }
        XCTAssertEqual(try fixture.store.scopeStop(scope: first, mode: .pause), .paused)
        expect(.invalidScope) { try fixture.scope(key: "other") }
        expect(.invalidScope) { try fixture.scope(deadline: 1_001) }
        let second = try fixture.scope()
        XCTAssertEqual(try fixture.store.scopeStop(scope: first, mode: .cancel), .cancelled)
        fixture.store.scopeClose(scope: first)
        expect(.invalidScope) { try fixture.store.readPass(token: fixture.token, scope: first, passId: oldPass, offset: 0, length: 1) }
        let pass = try fixture.store.beginPass(token: fixture.token, scope: second)
        XCTAssertEqual(try fixture.store.readPass(token: fixture.token, scope: second, passId: pass, offset: 0, length: 3), Data("abc".utf8))
        try fixture.store.finishPass(token: fixture.token, scope: second, passId: pass)
        XCTAssertEqual(try fixture.store.scopeStop(scope: second, mode: .cancel), .cancelled)
        XCTAssertEqual(try fixture.store.scopeStop(scope: second, mode: .pause), .cancelled)
        expect(.stopped) { try fixture.scope() }
        fixture.store.scopeClose(scope: second)
        expect(.stopped) { try fixture.scope() }
    }

    func testExpiryRollbackAndClockFailurePreventEveryFurtherFilesystemCall() throws {
        let samples: [Int64?] = [1_000, 99, nil]
        for sample in samples {
            let clock = SourceTestClock(100)
            let io = SourceTestIO()
            let fixture = try SourceFixture(clock: clock, io: io)
            defer { fixture.close() }
            let scope = try fixture.scope()
            let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
            let calls = io.calls.value
            clock.set(sample)
            let expected: SourceFileError = sample == 1_000 ? .expired : .clockFailure
            expect(expected) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 1) }
            XCTAssertEqual(io.calls.value, calls)
            if expected == .clockFailure {
                clock.set(101)
                expect(.clockFailure) { try fixture.scope() }
            }
        }
        let fixture = try SourceFixture()
        defer { fixture.close() }
        expect(.invalidScope) { try fixture.scope(deadline: 0) }
        let maximumDeadlineScope = try fixture.scope(deadline: Int64.max)
        XCTAssertEqual(try fixture.store.scopeStop(scope: maximumDeadlineScope, mode: .pause), .paused)
    }

    func testStopDuringAdmittedReadIsImmediateAndQueuedReadDoesNoNewIO() throws {
        let io = SourceTestIO()
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let results = SourceTestResults<Data>()
        io.beforeRead = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        DispatchQueue.global().async {
            results.add(Result { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) })
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            XCTAssertEqual(try? fixture.store.scopeStop(scope: scope, mode: .pause), .paused)
            stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.failure, .stopped)
        io.beforeRead = nil
        let calls = io.calls.value
        expect(.stopped) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) }
        expect(.stopped) { try fixture.store.finishPass(token: fixture.token, scope: scope, passId: pass) }
        expect(.stopped) { try fixture.store.validateSourceDelivery(token: fixture.token, scope: scope, passId: pass) }
        XCTAssertEqual(io.calls.value, calls)
    }

    func testReleaseAndShutdownGateReadButDeferDescriptorCloseUntilItReturns() throws {
        for shutdown in [false, true] {
            let io = SourceTestIO()
            let fixture = try SourceFixture(io: io)
            defer { fixture.close() }
            let scope = try fixture.scope()
            let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
            let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
            let results = SourceTestResults<Data>()
            io.beforeRead = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
            io.afterClose = { closed.signal() }
            DispatchQueue.global().async {
                results.add(Result { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) })
                finished.signal()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            if shutdown { fixture.store.shutdown() } else { fixture.store.release(token: fixture.token) }
            XCTAssertEqual(io.closes.value, 0)
            proceed.signal()
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(results.failure, .stopped)
            XCTAssertEqual(closed.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(io.closes.value, 1)
        }
    }

    func testScopeOpenDuringLegacyReadRejectsLateResultAndNextMetadataCall() throws {
        let io = SourceTestIO()
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let results = SourceTestResults<Data>()
        io.beforeRead = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        DispatchQueue.global().async {
            results.add(Result { try fixture.store.read(token: fixture.token, offset: 0, length: 3) })
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let calls = io.calls.value
        let scope = try fixture.scope()
        proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(results.hasFailure)
        XCTAssertEqual(io.calls.value, calls)
        io.beforeRead = nil
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        XCTAssertEqual(try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3), Data("abc".utf8))
    }

    func testEmptyPassSourceMutationAndUnrelatedSelection() throws {
        let fixture = try SourceFixture(bytes: Data())
        defer { fixture.close() }
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        try fixture.store.finishPass(token: fixture.token, scope: scope, passId: pass)
        let otherURL = fixture.root.appendingPathComponent("other")
        try Data("other".utf8).write(to: otherURL)
        let other = try XCTUnwrap(fixture.store.add([otherURL]).first).token
        _ = try fixture.store.scopeStop(scope: scope, mode: .cancel)
        XCTAssertEqual(try fixture.store.read(token: other, offset: 0, length: 5), Data("other".utf8))
        let otherScope = try fixture.store.scopeOpen(token: other, key: "other", deadlineMicros: 1_000)
        let otherPass = try fixture.store.beginPass(token: other, scope: otherScope)
        try FileManager.default.moveItem(at: otherURL, to: fixture.root.appendingPathComponent("old"))
        try Data("other".utf8).write(to: otherURL)
        expect(.sourceChanged) { try fixture.store.readPass(token: other, scope: otherScope, passId: otherPass, offset: 0, length: 5) }
    }

    func testScopeBoundAndSelectionReleaseRemainTerminal() throws {
        let fixture = try SourceFixture()
        defer { fixture.close() }
        var scope = try fixture.scope()
        for _ in 1..<SelectedFileStore.maximumFiles {
            _ = try fixture.store.scopeStop(scope: scope, mode: .pause)
            scope = try fixture.scope()
        }
        _ = try fixture.store.scopeStop(scope: scope, mode: .pause)
        expect(.resourceLimit) { try fixture.scope() }
        fixture.store.release(token: fixture.token)
        expect(.invalidToken) { try fixture.scope() }
        expect(.invalidToken) { try fixture.store.beginPass(token: fixture.token, scope: scope) }
    }

    func testStopBetweenMetadataCallsPreventsTheFollowingPathStat() throws {
        let io = SourceTestIO()
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        io.afterSnapshot = { _ = try? fixture.store.scopeStop(scope: scope, mode: .cancel) }
        let calls = io.calls.value
        expect(.stopped) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) }
        XCTAssertEqual(io.calls.value, calls + 1)
        io.afterSnapshot = nil
    }

    func testNewPassInvalidatesOldReadBeforeWaitingForItsWorkLock() throws {
        let io = SourceTestIO()
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let invalidated = DispatchSemaphore(value: 0), readFinished = DispatchSemaphore(value: 0), beginFinished = DispatchSemaphore(value: 0)
        let readResult = SourceTestResults<Data>(), beginResult = SourceTestResults<String>()
        io.beforeRead = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        io.afterPassInvalidated = { invalidated.signal() }
        DispatchQueue.global().async {
            readResult.add(Result { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) })
            readFinished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            beginResult.add(Result { try fixture.store.beginPass(token: fixture.token, scope: scope) })
            beginFinished.signal()
        }
        XCTAssertEqual(invalidated.wait(timeout: .now() + 5), .success)
        proceed.signal()
        XCTAssertEqual(readFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(beginFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readResult.failure, .invalidRead)
        io.beforeRead = nil; io.afterPassInvalidated = nil
        let replacement = try XCTUnwrap(beginResult.success)
        XCTAssertNotEqual(replacement, pass)
        expect(.invalidRead) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3) }
        XCTAssertEqual(try fixture.store.readPass(token: fixture.token, scope: scope, passId: replacement, offset: 0, length: 3), Data("abc".utf8))
    }

    func testRetiredHandlesStillOccupySelectionCapacityUntilPhysicalClose() throws {
        let io = SourceTestIO()
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let others = try fixture.store.add(Array(repeating: fixture.url, count: SelectedFileStore.maximumFiles - 1))
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        var first = true // Accessed only by the serial cleanup queue.
        io.beforeClose = {
            if first { first = false; entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        }
        io.afterClose = { closed.signal() }
        for token in [fixture.token] + others.map(\.token) { fixture.store.release(token: token) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try fixture.store.add([fixture.url])) { XCTAssertEqual($0 as? SelectedFileError, .limit) }
        proceed.signal()
        for _ in 0..<SelectedFileStore.maximumFiles { XCTAssertEqual(closed.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(try fixture.store.add([fixture.url]).count, 1)
    }

    func testShortReadsAndInterruptionRecheckStopBeforeEveryNextRead() throws {
        let io = SourceTestIO()
        io.maximumRead = 1
        io.interruptions = 1
        let fixture = try SourceFixture(io: io)
        defer { fixture.close() }
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        XCTAssertEqual(try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 3), Data("abc".utf8))
        XCTAssertEqual(io.reads.value, 4)
        let next = try fixture.store.beginPass(token: fixture.token, scope: scope)
        io.afterRead = { _ = try? fixture.store.scopeStop(scope: scope, mode: .cancel) }
        expect(.stopped) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: next, offset: 0, length: 3) }
        XCTAssertEqual(io.reads.value, 5)
        io.afterRead = nil
    }

    func testClockRollbackPoisonsUnrelatedLegacyPassesAndNewSelection() throws {
        let clock = SourceTestClock(100)
        let io = SourceTestIO()
        let fixture = try SourceFixture(clock: clock, io: io)
        defer { fixture.close() }
        let local = try fixture.store.add([fixture.url, fixture.url])
        XCTAssertEqual(try fixture.store.read(token: local[0].token, offset: 0, length: 1), Data("a".utf8))
        let oldPass = try fixture.store.beginReadPass(token: local[1].token)
        let scope = try fixture.scope()
        let pass = try fixture.store.beginPass(token: fixture.token, scope: scope)
        clock.set(99)
        expect(.clockFailure) { try fixture.store.readPass(token: fixture.token, scope: scope, passId: pass, offset: 0, length: 1) }
        clock.set(101) // The poisoned clock never becomes usable again.
        let calls = io.calls.value
        XCTAssertThrowsError(try fixture.store.read(token: local[0].token, offset: 1, length: 2))
        XCTAssertThrowsError(try fixture.store.finish(token: local[0].token))
        XCTAssertThrowsError(try fixture.store.beginReadPass(token: local[0].token))
        XCTAssertThrowsError(try fixture.store.readPass(token: local[1].token, passId: oldPass, offset: 0, length: 1))
        XCTAssertThrowsError(try fixture.store.finishPass(token: local[1].token, passId: oldPass))
        XCTAssertThrowsError(try fixture.store.add([fixture.url]))
        XCTAssertThrowsError(try fixture.store.validateLegacyDelivery(token: local[0].token))
        XCTAssertEqual(io.calls.value, calls)
    }

    private func expect<T>(_ error: SourceFileError, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> T) {
        XCTAssertThrowsError(try work(), file: file, line: line) { XCTAssertEqual($0 as? SourceFileError, error, file: file, line: line) }
    }
}

private final class SourceFixture {
    let root: URL, url: URL
    let store: SelectedFileStore
    let token: String
    init(bytes: Data = Data("abc".utf8), clock: SourceTestClock = SourceTestClock(100), io: SelectedFileIO = SelectedFileIO()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        url = root.appendingPathComponent("source")
        try bytes.write(to: url)
        store = SelectedFileStore(clock: { try clock.read() }, io: io)
        token = try XCTUnwrap(store.add([url]).first).token
    }
    func scope(key: String = "key", deadline: Int64 = 1_000) throws -> String {
        try store.scopeOpen(token: token, key: key, deadlineMicros: deadline)
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private final class SourceTestClock {
    private let lock = NSLock()
    private var value: Int64?
    init(_ value: Int64) { self.value = value }
    func set(_ value: Int64?) { lock.lock(); self.value = value; lock.unlock() }
    func read() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw SourceFileError.clockFailure }
        return value
    }
}

private final class SourceTestCounter {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SourceTestResults<T> {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func add(_ value: Result<T, Error>) { lock.lock(); result = value; lock.unlock() }
    var failure: SourceFileError? {
        lock.lock(); defer { lock.unlock() }
        if let result, case .failure(let error) = result { return error as? SourceFileError }
        return nil
    }
    var success: T? { lock.lock(); defer { lock.unlock() }; if let result, case .success(let value) = result { return value }; return nil }
    var hasFailure: Bool { lock.lock(); defer { lock.unlock() }; if let result, case .failure = result { return true }; return false }
}

private final class SourceTestIO: SelectedFileIO {
    let calls = SourceTestCounter(), closes = SourceTestCounter(), reads = SourceTestCounter()
    var maximumRead = Int.max
    var interruptions = 0
    var beforeRead: (() -> Void)?
    var afterRead: (() -> Void)?
    var afterSnapshot: (() -> Void)?
    var afterPassInvalidated: (() -> Void)?
    var beforeClose: (() -> Void)?
    var afterClose: (() -> Void)?
    override func snapshot(_ fd: Int32) throws -> stat { calls.add(); let value = try super.snapshot(fd); afterSnapshot?(); return value }
    override func didInvalidatePass() { afterPassInvalidated?() }
    override func pathSnapshot(_ url: URL) throws -> stat { calls.add(); return try super.pathSnapshot(url) }
    override func rewind(_ fd: Int32) throws { calls.add(); try super.rewind(fd) }
    override func read(_ fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        calls.add(); reads.add(); beforeRead?()
        if interruptions > 0 { interruptions -= 1; throw SelectedReadInterrupted() }
        let value = try super.read(fd, buffer: buffer, count: min(count, maximumRead))
        afterRead?()
        return value
    }
    override func close(_ fd: Int32) { beforeClose?(); super.close(fd); closes.add(); afterClose?() }
}
