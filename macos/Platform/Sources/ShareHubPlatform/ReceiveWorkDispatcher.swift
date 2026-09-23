import Foundation

public enum ReceiveDispatchError: Error, Equatable { case closed, resourceLimit }

/// Main-thread submission/completion ownership with two bounded I/O workers.
/// A slot remains occupied until its completion is delivered, not merely until
/// the worker finishes. Workers never retain or invoke channel callbacks.
public final class ReceiveWorkDispatcher {
    public typealias Completion = (Result<Any?, Error>) -> Void
    private struct Job {
        let id: UInt64
        let keys: Set<String>
        let work: () throws -> Any?
    }
    private let queue: OperationQueue
    private let maximumPending: Int
    private let lifetime = Lifetime()
    private var pending: [UInt64: Completion] = [:]
    private var jobs: [Job] = []
    private var activeKeys: Set<String> = []
    private var active = 0
    private var next: UInt64 = 0

    public convenience init() { self.init(queue: OperationQueue()) }

    internal init(queue: OperationQueue, maximumPending: Int = 64) {
        self.queue = queue
        self.maximumPending = maximumPending
        queue.name = "dev.sharehub.receive.work"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
    }

    public func submit(keys: [String] = [], work: @escaping () throws -> Any?, completion: @escaping Completion) throws {
        precondition(Thread.isMainThread)
        guard !lifetime.isClosed else { throw ReceiveDispatchError.closed }
        guard pending.count < maximumPending, next < UInt64.max else { throw ReceiveDispatchError.resourceLimit }
        next += 1
        let id = next
        pending[id] = completion
        jobs.append(Job(id: id, keys: Set(keys), work: work))
        dispatchEligible()
    }

    private func dispatchEligible() {
        precondition(Thread.isMainThread)
        guard !lifetime.isClosed else { return }
        while active < 2 {
            // Blocked earlier jobs reserve all their keys too. For example an
            // entry+scope job waiting for that entry cannot be overtaken by a
            // later scope-only operation. Unrelated work remains eligible.
            var unavailable = activeKeys
            var selected: Int?
            for (index, job) in jobs.enumerated() {
                if job.keys.isDisjoint(with: unavailable) { selected = index; break }
                unavailable.formUnion(job.keys)
            }
            guard let selected else { return }
            let job = jobs.remove(at: selected)
            active += 1
            activeKeys.formUnion(job.keys)
            dispatch(job)
        }
    }

    private func dispatch(_ job: Job) {
        let lifetime = self.lifetime
        queue.addOperation { [weak self] in
            guard !lifetime.isClosed else { return }
            let value = Result { try job.work() }
            guard !lifetime.isClosed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !lifetime.isClosed, let reply = self.pending.removeValue(forKey: job.id) else { return }
                self.active -= 1
                self.activeKeys.subtract(job.keys)
                reply(value)
                self.dispatchEligible()
            }
        }
    }

    /// The owner must synchronously gate native storage before calling close.
    /// Existing callbacks receive closed while the engine is still alive;
    /// later worker completions are discarded and cannot call the engine.
    public func close() {
        precondition(Thread.isMainThread)
        guard lifetime.close() else { return }
        queue.cancelAllOperations()
        jobs.removeAll()
        activeKeys.removeAll()
        let replies = Array(pending.values)
        pending.removeAll()
        for reply in replies { reply(.failure(ReceiveDispatchError.closed)) }
    }

    deinit {
        _ = lifetime.close()
        queue.cancelAllOperations()
    }

    private final class Lifetime {
        private let lock = NSLock()
        private var closed = false
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        func close() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return false }
            closed = true
            return true
        }
    }
}
