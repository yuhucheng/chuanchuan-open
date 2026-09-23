import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ShareHubPlatform

final class ReceiveStoreTests: XCTestCase {
    func testConfiguredDirectorySurvivesRestartWithoutOldTokens() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let preferences = ReceiveDirectoryPreferences(file: fixture.root.appendingPathComponent("setting.plist"))
        let first = ReceiveStore(clock: { 100 }, preferences: preferences)
        let original = try first.directoryFromPicker(fixture.root)
        first.shutdown()
        let restarted = ReceiveStore(clock: { 100 }, preferences: preferences)
        defer { restarted.shutdown() }
        let destination = try restarted.directoryConfigured()
        XCTAssertNotEqual(destination.token, original.token)
        let scope = try restarted.scopeOpen(key: "fresh-file", deadlineMicros: 10000)
        expect(.invalidToken) { try restarted.begin(directory: original.token, scope: scope, name: "old", size: 0, sha256: self.emptyHash) }
        let token = try restarted.begin(directory: destination.token, scope: scope, name: "persisted.txt", size: 0, sha256: emptyHash)
        let receipt = try restarted.commit(token: token, scope: scope)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(receipt.name)), Data())
    }

    func testCorruptDirectoryPreferenceFailsUntilExplicitSelection() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let file = fixture.root.appendingPathComponent("setting.plist")
        try Data([1, 2, 3]).write(to: file)
        let store = ReceiveStore(clock: { 100 }, preferences: ReceiveDirectoryPreferences(file: file))
        defer { store.shutdown() }
        expect(.settingsUnavailable) { try store.directoryConfigured() }
        _ = try store.directoryFromPicker(fixture.root)
        XCTAssertFalse(try store.directoryConfigured().token.isEmpty)
    }

    func testReplacedConfiguredDirectoryDoesNotFollowBookmarkToMovedLocation() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let preferences = ReceiveDirectoryPreferences(file: fixture.root.appendingPathComponent("setting.plist"))
        let chosen = fixture.root.appendingPathComponent("chosen")
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let first = ReceiveStore(clock: { 100 }, preferences: preferences)
        _ = try first.directoryFromPicker(chosen)
        first.shutdown()
        try FileManager.default.moveItem(at: chosen, to: moved)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let restarted = ReceiveStore(clock: { 100 }, preferences: preferences)
        defer { restarted.shutdown() }
        expect(.directoryChanged) { try restarted.directoryConfigured() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [])
    }

    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testEmptyAndMultichunkCommitProduceRealFilesAndReceipts() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let empty = try fixture.begin(name: "empty", bytes: Data())
        let receipt = try fixture.store.commit(token: empty.token, scope: empty.scope)
        XCTAssertEqual(receipt.sha256, emptyHash)
        XCTAssertEqual(receipt.size, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(receipt.name)), Data())
        let bytes = Data((0..<70_001).map { UInt8($0 % 251) })
        let item = try fixture.begin(name: "内容.bin", bytes: bytes)
        try fixture.append(item, bytes: bytes)
        let result = try fixture.store.commit(token: item.token, scope: item.scope)
        XCTAssertEqual(result.sha256, digest(bytes))
        XCTAssertEqual(result.size, Int64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(result.name)), bytes)
        XCTAssertEqual(try fixture.store.scopeStop(scope: item.scope, mode: .cancel), .committed)
        fixture.store.abort(token: item.token)
        try fixture.store.release(token: item.token)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(result.name)), bytes)
    }

    func testConcurrentSameNamesNeverOverwriteAndReturnActualNames() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try Data("original".utf8).write(to: fixture.root.appendingPathComponent("report.txt"))
        let items = try (0..<8).map { index -> (Item, Data) in
            let bytes = Data("payload-\(index)".utf8)
            let item = try fixture.begin(name: "report.txt", bytes: bytes, key: "key-\(index)")
            try fixture.append(item, bytes: bytes)
            return (item, bytes)
        }
        let results = LockedResults()
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            do { results.add(.success(try fixture.store.commit(token: items[index].0.token, scope: items[index].0.scope))) }
            catch { results.add(.failure(error)) }
        }
        let receipts = try results.values.map { try $0.get() }
        XCTAssertEqual(Set(receipts.map(\.name)).count, 8)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("report.txt")), Data("original".utf8))
        for receipt in receipts {
            let actual = try Data(contentsOf: fixture.root.appendingPathComponent(receipt.name))
            XCTAssertEqual(digest(actual), receipt.sha256)
            XCTAssertTrue(items.contains { $0.1 == actual })
        }
    }

    func testUnsafeNamesAndLinkedDirectoryAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for name in ["", ".", "..", "../escape", "/absolute", "a/b", "a\\b", "a:b", "CON", "nul.txt", "COM1.txt", "LPT9", "trail.", "trail ", "a\u{0}b", "a\n", String(repeating: "x", count: 256)] {
            let scope = try fixture.scope()
            expect(.invalidName) { try fixture.store.begin(directory: fixture.directory.token, scope: scope, name: name, size: 0, sha256: self.emptyHash) }
            fixture.store.scopeClose(scope: scope)
        }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        expect(.directoryChanged) { try fixture.store.directoryFromPicker(link) }
        let nested = link.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        expect(.directoryChanged) { try fixture.store.directoryFromPicker(nested) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testTempIsExclusiveOwnerOnlyAndNoFinalPlaceholderExists() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try fixture.begin(name: "report", bytes: Data("abc".utf8))
        let temporary = try fixture.onlyTemporary()
        var info = stat()
        XCTAssertEqual(lstat(temporary.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(info.st_nlink, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("report").path))
    }

    func testWholeOriginalHandleHashRejectsSameLengthMutationAndExtraTail() throws {
        for contents in [Data("abd".utf8), Data("abc!".utf8)] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let item = try fixture.begin(name: "final", bytes: Data("abc".utf8))
            try fixture.append(item, bytes: Data("abc".utf8))
            try overwrite(try fixture.onlyTemporary(), bytes: contents)
            XCTAssertThrowsError(try fixture.store.commit(token: item.token, scope: item.scope))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("final").path))
        }
    }

    func testDeclaredHashMismatchNeverPublishes() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let scope = try fixture.scope()
        let token = try fixture.store.begin(directory: fixture.directory.token, scope: scope, name: "bad", size: 3, sha256: emptyHash)
        _ = try fixture.store.append(token: token, scope: scope, offset: 0, bytes: Data("abc".utf8))
        expect(.integrityMismatch) { try fixture.store.commit(token: token, scope: scope) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("bad").path))
    }

    func testExactOffsetsRangeScopeAndLateWritesAreRejected() throws {
        for invalid in [(-1, Data([1])), (1, Data([1])), (0, Data()), (0, Data(repeating: 1, count: 32_769)), (0, Data(repeating: 1, count: 4)), (Int64.max, Data([1]))] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let item = try fixture.begin(name: "range", bytes: Data("abc".utf8))
            expect(.invalidRange) { try fixture.store.append(token: item.token, scope: item.scope, offset: invalid.0, bytes: invalid.1) }
            XCTAssertThrowsError(try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data([1])))
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = try fixture.begin(name: "scope", bytes: Data("abc".utf8))
        let other = try fixture.scope()
        expect(.staleScope) { try fixture.store.append(token: item.token, scope: other, offset: 0, bytes: Data([1])) }
        XCTAssertEqual(try fixture.store.checkpoint(token: item.token).offset, 0)
    }

    func testOriginalDeadlineClockFailureAndRollbackFailClosed() throws {
        for next in [Int64?(1_000), Int64?(99), nil] {
            let clock = TestClock(100)
            let fixture = try Fixture(clock: clock)
            defer { fixture.close() }
            let item = try fixture.begin(name: "deadline", bytes: Data("abc".utf8))
            clock.set(next)
            expect(next == 1_000 ? .expired : .clockUnavailable) {
                try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data("abc".utf8))
            }
            clock.set(101)
            XCTAssertThrowsError(try fixture.store.commit(token: item.token, scope: item.scope))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("deadline").path))
        }
    }

    func testPartialWritesAndReadsLoopAndInjectedDiskFullNeverPublishes() throws {
        let io = ControlledIO()
        io.maximumWrite = 1
        io.maximumRead = 1
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "partial", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        XCTAssertEqual(try fixture.store.commit(token: item.token, scope: item.scope).sha256, abcHash)
        let failing = try fixture.begin(name: "disk-full", bytes: Data("abc".utf8), key: "other")
        io.writesBeforeFailure = 1
        expect(.diskFull) { try fixture.store.append(token: failing.token, scope: failing.scope, offset: 0, bytes: Data("abc".utf8)) }
        XCTAssertThrowsError(try fixture.store.commit(token: failing.token, scope: failing.scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("disk-full").path))
    }

    func testInjectedReadFlushAndRenameFailuresNeverReturnReceipts() throws {
        for stage in ["read", "flush", "rename"] {
            let io = ControlledIO()
            let fixture = try Fixture(io: io)
            defer { fixture.close() }
            let item = try fixture.begin(name: stage, bytes: Data("abc".utf8))
            try fixture.append(item, bytes: Data("abc".utf8))
            io.failureStage = stage
            XCTAssertThrowsError(try fixture.store.commit(token: item.token, scope: item.scope))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(stage).path))
        }
        let io = ControlledIO()
        io.maximumRead = 1
        io.readsBeforeFailure = 1
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "partial-read", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        expect(.ioFailure) { try fixture.store.commit(token: item.token, scope: item.scope) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("partial-read").path))
    }

    func testPauseCheckpointUsesCachedHashAndResumeRequiresSameOriginalAuthorization() throws {
        let io = ControlledIO()
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "resumed", bytes: Data("abcdef".utf8))
        _ = try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data("abc".utf8))
        XCTAssertEqual(try fixture.store.scopeStop(scope: item.scope, mode: .pause), .paused)
        io.failureStage = "read"
        let checkpoint = try fixture.store.checkpoint(token: item.token)
        XCTAssertEqual(checkpoint.offset, 3)
        XCTAssertEqual(checkpoint.sha256, abcHash)
        XCTAssertEqual(try fixture.store.checkpoint(token: item.token), checkpoint)
        io.failureStage = nil
        let scope = try fixture.scope()
        try fixture.store.resume(token: item.token, scope: scope, checkpoint: checkpoint)
        _ = try fixture.store.append(token: item.token, scope: scope, offset: 3, bytes: Data("def".utf8))
        let receipt = try fixture.store.commit(token: item.token, scope: scope)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(receipt.name)), Data("abcdef".utf8))
    }

    func testResumeRejectsChangedPrefixExtraTailStaleCheckpointKeyAndDeadline() throws {
        for kind in ["prefix", "tail", "checkpoint", "key", "deadline", "cancel"] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let item = try fixture.begin(name: "resume", bytes: Data("abcdef".utf8))
            _ = try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data("abc".utf8))
            _ = try fixture.store.scopeStop(scope: item.scope, mode: .pause)
            var checkpoint = try fixture.store.checkpoint(token: item.token)
            if kind == "prefix" { try overwrite(try fixture.onlyTemporary(), bytes: Data("abd".utf8)) }
            if kind == "tail" { try overwrite(try fixture.onlyTemporary(), bytes: Data("abc!".utf8)) }
            if kind == "checkpoint" { checkpoint = ReceiveCheckpoint(offset: 2, sha256: abcHash, identity: checkpoint.identity) }
            if kind == "cancel" { _ = try fixture.store.scopeStop(scope: item.scope, mode: .cancel) }
            let scope = try fixture.store.scopeOpen(key: kind == "key" ? "different" : "key", deadlineMicros: kind == "deadline" ? 1_001 : 1_000)
            XCTAssertThrowsError(try fixture.store.resume(token: item.token, scope: scope, checkpoint: checkpoint))
            XCTAssertThrowsError(try fixture.store.append(token: item.token, scope: scope, offset: 3, bytes: Data("def".utf8)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resume").path))
        }
    }

    func testStopDuringBlockedHashReturnsWithoutWaitingAndPreventsPublish() throws {
        let io = ControlledIO()
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let bytes = Data(repeating: 7, count: 600_000)
        let item = try fixture.begin(name: "cancelled", bytes: bytes)
        try fixture.append(item, bytes: bytes)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        io.beforeRead = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        let finished = expectation(description: "hash stopped")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            XCTAssertThrowsError(try fixture.store.commit(token: item.token, scope: item.scope))
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try fixture.store.scopeStop(scope: item.scope, mode: .cancel), .cancelled)
        proceed.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancelled").path))
        XCTAssertThrowsError(try fixture.store.append(token: item.token, scope: item.scope, offset: Int64(bytes.count), bytes: Data([1])))
    }

    func testCommitWinnerReportsCommittingAndLateCancelCannotDeletePublishedFile() throws {
        let io = ControlledIO()
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "winner", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        io.beforeRename = { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
        let finished = expectation(description: "committed")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            XCTAssertNoThrow(try fixture.store.commit(token: item.token, scope: item.scope))
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try fixture.store.scopeStop(scope: item.scope, mode: .cancel), .committing)
        fixture.store.abort(token: item.token)
        proceed.signal()
        wait(for: [finished], timeout: 5)
        try fixture.store.retryCleanup(token: item.token)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("winner")), Data("abc".utf8))
    }

    func testDirectoryAndTempReplacementAreDetectedWithoutTouchingReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = try fixture.begin(name: "final", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        let temp = try fixture.onlyTemporary()
        let original = fixture.root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: temp, to: original)
        try Data("replacement".utf8).write(to: temp)
        expect(.sourceChanged) { try fixture.store.commit(token: item.token, scope: item.scope) }
        expect(.cleanupFailed) { try fixture.store.retryCleanup(token: item.token) }
        XCTAssertEqual(try Data(contentsOf: temp), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("abc".utf8))
        let second = try Fixture()
        defer { second.close() }
        let waiting = try second.begin(name: "final", bytes: Data("abc".utf8))
        let moved = second.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: second.root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: second.root, withIntermediateDirectories: false)
        expect(.directoryChanged) { try second.store.append(token: waiting.token, scope: waiting.scope, offset: 0, bytes: Data("abc".utf8)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.root.path), [])
    }

    func testCleanupFailureRetainsExactObjectAndRetryRemovesIt() throws {
        let io = ControlledIO()
        io.failureStage = "unlink"
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "cleanup", bytes: Data("abc".utf8))
        fixture.store.abort(token: item.token)
        expect(.cleanupFailed) { try fixture.store.retryCleanup(token: item.token) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 1)
        XCTAssertThrowsError(try fixture.store.release(token: item.token))
        io.failureStage = nil
        try fixture.store.retryCleanup(token: item.token)
        try fixture.store.release(token: item.token)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testLimitsReleaseDirectoryRetentionAndShutdown() throws {
        let fixture = try Fixture(maximumReservedBytes: 3)
        defer { fixture.close() }
        let item = try fixture.begin(name: "first", bytes: Data("abc".utf8))
        let otherScope = try fixture.scope(key: "other")
        expect(.resourceLimit) { try fixture.store.begin(directory: fixture.directory.token, scope: otherScope, name: "second", size: 1, sha256: self.abcHash) }
        XCTAssertThrowsError(try fixture.store.release(token: item.token))
        fixture.store.directoryRelease(token: fixture.directory.token)
        try fixture.append(item, bytes: Data("abc".utf8))
        XCTAssertEqual(try fixture.store.commit(token: item.token, scope: item.scope).name, "first")
        fixture.store.shutdown()
        XCTAssertThrowsError(try fixture.store.scopeOpen(key: "key", deadlineMicros: 1_000))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("first")), Data("abc".utf8))
    }

    func testScopeCountAndOneFilePerScopeAreBounded() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = try fixture.begin(name: "one", bytes: Data())
        expect(.staleScope) { try fixture.store.begin(directory: fixture.directory.token, scope: item.scope, name: "two", size: 0, sha256: self.emptyHash) }
        for _ in 1..<64 { _ = try fixture.scope() }
        expect(.resourceLimit) { try fixture.scope() }
        fixture.store.scopeClose(scope: item.scope)
        XCTAssertNoThrow(try fixture.scope())
        XCTAssertThrowsError(try fixture.store.commit(token: item.token, scope: item.scope))
    }

    func testHardlinkPreventsCommitAndCleanupNeverDeletesTheOtherLink() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let item = try fixture.begin(name: "final", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        let temporary = try fixture.onlyTemporary()
        let other = fixture.root.appendingPathComponent("other-link")
        XCTAssertEqual(link(temporary.path, other.path), 0)
        expect(.sourceChanged) { try fixture.store.commit(token: item.token, scope: item.scope) }
        expect(.cleanupFailed) { try fixture.store.retryCleanup(token: item.token) }
        XCTAssertEqual(try Data(contentsOf: other), Data("abc".utf8))
        try FileManager.default.removeItem(at: other)
        try fixture.store.retryCleanup(token: item.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testEntryLimitCanBeReusedAfterCommittedMetadataRelease() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var completed: [String] = []
        for index in 0..<64 {
            let item = try fixture.begin(name: "file-\(index)", bytes: Data())
            _ = try fixture.store.commit(token: item.token, scope: item.scope)
            fixture.store.scopeClose(scope: item.scope)
            completed.append(item.token)
        }
        let next = try fixture.scope()
        expect(.resourceLimit) { try fixture.store.begin(directory: fixture.directory.token, scope: next, name: "next", size: 0, sha256: self.emptyHash) }
        try fixture.store.release(token: completed[0])
        let token = try fixture.store.begin(directory: fixture.directory.token, scope: next, name: "next", size: 0, sha256: emptyHash)
        XCTAssertEqual(try fixture.store.commit(token: token, scope: next).name, "next")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("file-0").path))
    }

    func testNumberingReservesUnicodeNameSpaceAndExhaustionDoesNotOverwrite() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let name = String(repeating: "界", count: 84) + ".x"
        try Data("original".utf8).write(to: fixture.root.appendingPathComponent(name))
        let item = try fixture.begin(name: name, bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        let receipt = try fixture.store.commit(token: item.token, scope: item.scope)
        XCTAssertTrue(receipt.name.hasSuffix(" (1).x"))
        XCTAssertLessThanOrEqual(receipt.name.utf8.count, 255)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(name)), Data("original".utf8))
        let full = try fixture.begin(name: "taken", bytes: Data())
        for index in 0..<1_000 {
            let leaf = index == 0 ? "taken" : "taken (\(index))"
            try Data("keep".utf8).write(to: fixture.root.appendingPathComponent(leaf))
        }
        expect(.nameExhausted) { try fixture.store.commit(token: full.token, scope: full.scope) }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("taken (999)")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("taken (1000)").path))
    }

    func testExpiryDuringBlockedHashAndShutdownDoNotAllowResume() throws {
        let clock = TestClock(100)
        let io = ControlledIO()
        let fixture = try Fixture(io: io, clock: clock)
        defer { fixture.close() }
        let item = try fixture.begin(name: "expired", bytes: Data("abc".utf8))
        try fixture.append(item, bytes: Data("abc".utf8))
        io.beforeRead = { clock.set(1_000) }
        expect(.expired) { try fixture.store.commit(token: item.token, scope: item.scope) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("expired").path))
        let other = try Fixture()
        defer { other.close() }
        let paused = try other.begin(name: "paused", bytes: Data("abc".utf8))
        _ = try other.store.scopeStop(scope: paused.scope, mode: .pause)
        let checkpoint = try other.store.checkpoint(token: paused.token)
        let newScope = try other.scope()
        other.store.shutdown()
        XCTAssertThrowsError(try other.store.resume(token: paused.token, scope: newScope, checkpoint: checkpoint))
        XCTAssertThrowsError(try other.store.append(token: paused.token, scope: newScope, offset: 0, bytes: Data("abc".utf8)))
    }

    func testPauseDuringPartialWriteKeepsOnlyWrittenPrefixAndDoesNotAffectOtherScope() throws {
        let io = ControlledIO()
        io.maximumWrite = 1
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "pause", bytes: Data("abc".utf8))
        io.afterWrite = { _ = try? fixture.store.scopeStop(scope: item.scope, mode: .pause) }
        expect(.paused) { try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data("abc".utf8)) }
        let checkpoint = try fixture.store.checkpoint(token: item.token)
        XCTAssertEqual(checkpoint.offset, 1)
        XCTAssertEqual(checkpoint.sha256, "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb")
        io.afterWrite = nil
        let unrelated = try fixture.begin(name: "other", bytes: Data(), key: "unrelated")
        XCTAssertNoThrow(try fixture.store.commit(token: unrelated.token, scope: unrelated.scope))
        let next = try fixture.scope()
        try fixture.store.resume(token: item.token, scope: next, checkpoint: checkpoint)
        _ = try fixture.store.append(token: item.token, scope: next, offset: 1, bytes: Data("bc".utf8))
        XCTAssertEqual(try fixture.store.commit(token: item.token, scope: next).sha256, abcHash)
    }

    func testCancellingOldScopeDuringResumeHashCannotReactivateEntry() throws {
        let io = ControlledIO()
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let item = try fixture.begin(name: "resume-cancel", bytes: Data("abcdef".utf8))
        _ = try fixture.store.append(token: item.token, scope: item.scope, offset: 0, bytes: Data("abc".utf8))
        _ = try fixture.store.scopeStop(scope: item.scope, mode: .pause)
        let checkpoint = try fixture.store.checkpoint(token: item.token)
        let next = try fixture.scope()
        io.beforeRead = { _ = try? fixture.store.scopeStop(scope: item.scope, mode: .cancel) }
        expect(.cancelled) { try fixture.store.resume(token: item.token, scope: next, checkpoint: checkpoint) }
        io.beforeRead = nil
        XCTAssertThrowsError(try fixture.store.append(token: item.token, scope: next, offset: 3, bytes: Data("def".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("resume-cancel").path))
    }

    func testWrittenPrefixIsNotReservedAgainAgainstCurrentFreeSpace() throws {
        let io = ControlledIO()
        io.freeBytes = 6
        let fixture = try Fixture(io: io)
        defer { fixture.close() }
        let first = try fixture.begin(name: "first", bytes: Data("abc".utf8))
        try fixture.append(first, bytes: Data("abc".utf8))
        io.freeBytes = 3 // The written prefix already reduced current free space.
        let second = try fixture.begin(name: "second", bytes: Data("abc".utf8))
        try fixture.append(second, bytes: Data("abc".utf8))
        XCTAssertEqual(try fixture.store.commit(token: second.token, scope: second.scope).size, 3)
        XCTAssertEqual(try fixture.store.commit(token: first.token, scope: first.scope).size, 3)
    }

    func testScopeCancelAndCloseScheduleCleanupWithoutAnotherPublicWorkCall() throws {
        for closeScope in [false, true] {
            let io = ControlledIO()
            let cleaned = DispatchSemaphore(value: 0)
            io.afterUnlink = { cleaned.signal() }
            let fixture = try Fixture(io: io)
            defer { fixture.close() }
            let item = try fixture.begin(name: "cancel-cleanup", bytes: Data("abc".utf8))
            if closeScope { fixture.store.scopeClose(scope: item.scope) }
            else { XCTAssertEqual(try fixture.store.scopeStop(scope: item.scope, mode: .cancel), .cancelled) }
            XCTAssertEqual(cleaned.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
        }
    }

    func testFailedUnreturnedBeginCanRetryCleanupWithoutKnowingToken() throws {
        let io = ControlledIO()
        let clock = TestClock(100)
        let fixture = try Fixture(io: io, clock: clock)
        defer { fixture.close() }
        io.afterCreate = { clock.set(1_000) }
        io.failureStage = "unlink"
        expect(.expired) { try fixture.begin(name: "never-exposed", bytes: Data("abc".utf8)) }
        expect(.cleanupFailed) { try fixture.store.retryPendingCleanup() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 1)
        io.failureStage = nil
        try fixture.store.retryPendingCleanup()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testCancelAndCloseAfterRegistrationKeepUnreturnedCleanupOwnedUntilBeginExits() throws {
        for closeScope in [false, true] {
            let io = ControlledIO()
            let fixture = try Fixture(io: io)
            defer { fixture.close() }
            let scope = try fixture.scope()
            let cleanupFinished = DispatchSemaphore(value: 0)
            io.afterCleanup = { cleanupFinished.signal() }
            io.afterRegistration = { work in
                // This hook runs after registry insertion, before the final
                // authorization check. try() makes lock ownership observable
                // without a timeout-based assertion about worker scheduling.
                let acquired = work.try()
                if acquired { work.unlock() }
                XCTAssertFalse(acquired, "begin must retain serialization through failure bookkeeping")
                if closeScope { fixture.store.scopeClose(scope: scope) }
                else { XCTAssertEqual(try? fixture.store.scopeStop(scope: scope, mode: .cancel), .cancelled) }
                if acquired {
                    // Regression path: force the queued cleanup to close the
                    // descriptor before begin's final authorization check.
                    XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 5), .success)
                }
            }
            expect(.cancelled) {
                try fixture.store.begin(directory: fixture.directory.token, scope: scope,
                    name: "never-returned", size: 0, sha256: digest(Data()))
            }
            io.afterRegistration = nil
            XCTAssertEqual(cleanupFinished.wait(timeout: .now() + 5), .success)
            io.afterCleanup = nil
            fixture.store.scopeClose(scope: scope)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
            // No hidden cleaned entry may consume capacity after its token was
            // never returned. Keep all 64 entries live to verify the full bound.
            for index in 0..<ReceiveStore.maximumEntries {
                _ = try fixture.begin(name: "capacity-\(index)", bytes: Data())
            }
        }
    }

    func testUntrustedWritableDestinationAndInheritedAllowACLAreRejectedBeforeCreation() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertEqual(chmod(fixture.root.path, 0o777), 0)
        expect(.unsupportedStorage) { try fixture.store.directoryFromPicker(fixture.root) }
        let child = fixture.root.appendingPathComponent("owned-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        expect(.unsupportedStorage) { try fixture.store.directoryFromPicker(child) }
        // Sticky ancestors are supported only with trusted, owned children;
        // a sticky directory is still never admitted as the receive target.
        XCTAssertEqual(chmod(fixture.root.path, 0o1777), 0)
        expect(.unsupportedStorage) { try fixture.store.directoryFromPicker(fixture.root) }
        let ownedChild = try fixture.store.directoryFromPicker(child)
        fixture.store.directoryRelease(token: ownedChild.token)
        try FileManager.default.removeItem(at: child)
        XCTAssertEqual(chmod(fixture.root.path, 0o700), 0)
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", "everyone allow read,write,append,delete_child,file_inherit,directory_inherit", fixture.root.path]
        try command.run(); command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        expect(.unsupportedStorage) { try fixture.store.directoryFromPicker(fixture.root) }
        // The originally issued capability is rechecked too.
        expect(.unsupportedStorage) { try fixture.begin(name: "must-not-exist", bytes: Data("abc".utf8)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    private func expect<T>(_ code: ReceiveStoreError, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? ReceiveStoreError, code, file: file, line: line) }
    }
}

private func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

private func overwrite(_ url: URL, bytes: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
}

private struct Item { let token: String; let scope: String }

private final class Fixture {
    let root: URL
    let store: ReceiveStore
    let directory: ReceiveDirectory
    init(io: ReceiveStoreFileSystem = ReceiveStoreFileSystem(), clock: TestClock = TestClock(100), maximumReservedBytes: Int64? = nil) throws {
        // System temporary paths may contain /var -> /private/var. Resolve only
        // this test-created fixture before handing its URL to the strict walker.
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        store = ReceiveStore(clock: { try clock.read() }, maximumReservedBytes: maximumReservedBytes, fileSystem: io)
        directory = try store.directoryFromPicker(root)
    }
    func scope(key: String = "key") throws -> String { try store.scopeOpen(key: key, deadlineMicros: 1_000) }
    func begin(name: String, bytes: Data, key: String = "key") throws -> Item {
        let scope = try self.scope(key: key)
        return Item(token: try store.begin(directory: directory.token, scope: scope, name: name, size: Int64(bytes.count), sha256: digest(bytes)), scope: scope)
    }
    func append(_ item: Item, bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 32_768, bytes.count)
            XCTAssertEqual(try store.append(token: item.token, scope: item.scope, offset: Int64(offset), bytes: bytes.subdata(in: offset..<end)), Int64(end))
            offset = end
        }
    }
    func onlyTemporary() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".part") }
        return try XCTUnwrap(files.count == 1 ? files.first : nil)
    }
    func close() {
        store.shutdown()
        // Exact, newly created fixture tree only; never OS Downloads.
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TestClock {
    private let lock = NSLock()
    private var value: Int64?
    init(_ value: Int64) { self.value = value }
    func set(_ next: Int64?) { lock.lock(); value = next; lock.unlock() }
    func read() throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw ReceiveStoreError.clockUnavailable }
        return value
    }
}

private final class LockedResults {
    private let lock = NSLock()
    private var results: [Result<ReceiveReceipt, Error>] = []
    func add(_ result: Result<ReceiveReceipt, Error>) { lock.lock(); results.append(result); lock.unlock() }
    var values: [Result<ReceiveReceipt, Error>] { lock.lock(); defer { lock.unlock() }; return results }
}

private final class ControlledIO: ReceiveStoreFileSystem {
    private let stageLock = NSLock()
    private var stage: String?
    var maximumWrite = Int.max
    var maximumRead = Int.max
    var writesBeforeFailure: Int?
    var readsBeforeFailure: Int?
    var failureStage: String? {
        get { stageLock.lock(); defer { stageLock.unlock() }; return stage }
        set { stageLock.lock(); stage = newValue; stageLock.unlock() }
    }
    var beforeRead: (() -> Void)?
    var beforeRename: (() -> Void)?
    var afterWrite: (() -> Void)?
    var afterCreate: (() -> Void)?
    var afterUnlink: (() -> Void)?
    var afterRegistration: ((NSLock) -> Void)?
    var afterCleanup: (() -> Void)?
    var freeBytes: Int64?
    override func createTemporary(directory: Int32, name: String) throws -> Int32 {
        let fd = try super.createTemporary(directory: directory, name: name)
        afterCreate?()
        return fd
    }
    override func didRegisterTemporary(work: NSLock) { afterRegistration?(work) }
    override func didFinishCleanup() { afterCleanup?() }
    override func availableBytes(_ fd: Int32) throws -> Int64 {
        if let freeBytes { return freeBytes }
        return try super.availableBytes(fd)
    }
    override func write(_ fd: Int32, bytes: UnsafeRawPointer, count: Int, offset: Int64) throws -> Int {
        if let left = writesBeforeFailure {
            if left == 0 { throw ReceiveStoreSystemError(number: ENOSPC) }
            writesBeforeFailure = left - 1
        }
        let result = try super.write(fd, bytes: bytes, count: min(count, maximumWrite), offset: offset)
        afterWrite?()
        return result
    }
    override func read(_ fd: Int32, bytes: UnsafeMutableRawPointer, count: Int, offset: Int64) throws -> Int {
        beforeRead?()
        if failureStage == "read" { throw ReceiveStoreSystemError(number: EIO) }
        if let left = readsBeforeFailure {
            if left == 0 { throw ReceiveStoreSystemError(number: EIO) }
            readsBeforeFailure = left - 1
        }
        return try super.read(fd, bytes: bytes, count: min(count, maximumRead), offset: offset)
    }
    override func synchronize(_ fd: Int32) throws {
        if failureStage == "flush" { throw ReceiveStoreSystemError(number: EIO) }
        try super.synchronize(fd)
    }
    override func rename(directory: Int32, from: String, to: String) throws {
        beforeRename?()
        if failureStage == "rename" { throw ReceiveStoreSystemError(number: EACCES) }
        try super.rename(directory: directory, from: from, to: to)
    }
    override func unlink(directory: Int32, name: String) throws {
        if failureStage == "unlink" { throw ReceiveStoreSystemError(number: EACCES) }
        try super.unlink(directory: directory, name: name)
        afterUnlink?()
    }
}
