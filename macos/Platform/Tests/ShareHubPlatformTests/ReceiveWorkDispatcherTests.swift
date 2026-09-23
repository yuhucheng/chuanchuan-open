import Foundation
import XCTest
@testable import ShareHubPlatform

final class ReceiveWorkDispatcherTests: XCTestCase {
    func testUndeliveredCompletionStillConsumesCapacityAndCallbackIsMainThread() throws {
        let queue = OperationQueue()
        let dispatcher = ReceiveWorkDispatcher(queue: queue, maximumPending: 1)
        let finished = expectation(description: "main completion")
        try onMain {
            try dispatcher.submit(work: { 7 }) { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(try? result.get() as? Int, 7)
                finished.fulfill()
            }
            queue.waitUntilAllOperationsAreFinished()
            // Worker completion is queued to main but has not been delivered.
            XCTAssertThrowsError(try dispatcher.submit(work: { 8 }, completion: { _ in })) {
                XCTAssertEqual($0 as? ReceiveDispatchError, .resourceLimit)
            }
        }
        wait(for: [finished], timeout: 5)
        onMain { dispatcher.close() }
    }

    func testSixtyFourBoundIncludesTwoWorkersAndCloseDropsQueuedWork() throws {
        let queue = OperationQueue()
        let dispatcher = ReceiveWorkDispatcher(queue: queue)
        let firstTwo = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let counter = DispatchCounter()
        var completions = 0
        try onMain {
            for _ in 0..<64 {
                try dispatcher.submit(work: {
                    counter.increment()
                    firstTwo.signal()
                    _ = proceed.wait(timeout: .now() + 5)
                    return nil
                }) { result in
                    XCTAssertTrue(Thread.isMainThread)
                    if case .failure(let error) = result { XCTAssertEqual(error as? ReceiveDispatchError, .closed) }
                    else { XCTFail("closed job unexpectedly completed") }
                    completions += 1
                }
            }
            XCTAssertEqual(firstTwo.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(firstTwo.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(counter.value, 2)
            XCTAssertThrowsError(try dispatcher.submit(work: { nil }, completion: { _ in }))
            dispatcher.close()
            XCTAssertEqual(completions, 64)
            proceed.signal(); proceed.signal()
            queue.waitUntilAllOperationsAreFinished()
            XCTAssertEqual(counter.value, 2)
            XCTAssertThrowsError(try dispatcher.submit(work: { nil }, completion: { _ in })) {
                XCTAssertEqual($0 as? ReceiveDispatchError, .closed)
            }
        }
    }

    func testCloseDeliversOnceAndLateSuccessCannotCallbackAfterLifetime() throws {
        let queue = OperationQueue()
        let dispatcher = ReceiveWorkDispatcher(queue: queue)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var replies = 0
        let drained = expectation(description: "main queue drained")
        try onMain {
            try dispatcher.submit(work: {
                entered.signal()
                _ = proceed.wait(timeout: .now() + 5)
                return "late"
            }) { _ in replies += 1 }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            dispatcher.close()
            dispatcher.close()
            XCTAssertEqual(replies, 1)
            proceed.signal()
            queue.waitUntilAllOperationsAreFinished()
            DispatchQueue.main.async { XCTAssertEqual(replies, 1); drained.fulfill() }
        }
        wait(for: [drained], timeout: 5)
    }

    func testSharedKeysKeepSubmissionOrderWhileUnrelatedFileRunsInParallel() throws {
        let queue = OperationQueue()
        queue.isSuspended = true
        let dispatcher = ReceiveWorkDispatcher(queue: queue)
        let firstStarted = DispatchSemaphore(value: 0)
        let unrelatedStarted = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let events = DispatchEvents()
        let replies = expectation(description: "four ordered replies")
        replies.expectedFulfillmentCount = 4
        let completion: ReceiveWorkDispatcher.Completion = { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }
            replies.fulfill()
        }
        try onMain {
            try dispatcher.submit(keys: ["e:first"], work: {
                events.add(1); firstStarted.signal()
                XCTAssertEqual(proceed.wait(timeout: .now() + 5), .success)
                return nil
            }, completion: completion)
            // The second call reserves both keys while it waits for the first.
            try dispatcher.submit(keys: ["e:first", "s:scope"], work: {
                events.add(2); return nil
            }, completion: completion)
            try dispatcher.submit(keys: ["s:scope"], work: {
                events.add(3); return nil
            }, completion: completion)
            try dispatcher.submit(keys: ["e:unrelated"], work: {
                unrelatedStarted.signal(); return nil
            }, completion: completion)
            queue.isSuspended = false
            XCTAssertEqual(firstStarted.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(unrelatedStarted.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(events.values, [1])
            proceed.signal()
        }
        wait(for: [replies], timeout: 5)
        XCTAssertEqual(events.values, [1, 2, 3])
        onMain { dispatcher.close() }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}

private final class DispatchCounter {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class DispatchEvents {
    private let lock = NSLock()
    private var events: [Int] = []
    func add(_ value: Int) { lock.lock(); events.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return events }
}
