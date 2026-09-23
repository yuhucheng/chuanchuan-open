import Foundation

/// Main-thread ownership transaction for one OS-originated file batch.
/// Paths never cross the Flutter boundary. Source selection remains asynchronous.
final class FileDropSession {
    typealias Decision = (Bool) -> Void
    typealias Locate = (Double, Double, @escaping Decision) -> Void
    typealias Prepare = ([URL], @escaping (Result<[SelectedFileInfo], Error>) -> Void) -> Void
    typealias Offer = ([SelectedFileInfo], Double, Double, @escaping Decision) -> Void

    private let locate: Locate
    private let prepare: Prepare
    private let release: ([SelectedFileInfo]) -> Void
    private let offer: Offer
    private let onError: () -> Void
    private let holdURLs: ([URL]) -> () -> Void
    private var listening = false, busy = false, closed = false
    private var generation = UUID()
    private var pending: [SelectedFileInfo] = []
    private var lease: URLLease?

    init(locate: @escaping Locate, prepare: @escaping Prepare,
         release: @escaping ([SelectedFileInfo]) -> Void, offer: @escaping Offer,
         onError: @escaping () -> Void,
         holdURLs: @escaping ([URL]) -> () -> Void = { urls in
             let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
             return { for url in accessed { url.stopAccessingSecurityScopedResource() } }
         }) {
        self.locate = locate; self.prepare = prepare; self.release = release
        self.offer = offer; self.onError = onError; self.holdURLs = holdURLs
    }

    var ready: Bool { precondition(Thread.isMainThread); return listening && !busy && !closed }
    func listen() { precondition(Thread.isMainThread); if !closed { listening = true } }
    func cancel() {
        precondition(Thread.isMainThread)
        listening = false; generation = UUID()
        lease?.stop(); lease = nil
    }

    @discardableResult
    func accept(_ urls: [URL], x: Double, y: Double) -> Bool {
        precondition(Thread.isMainThread)
        guard ready, !urls.isEmpty, urls.count <= SelectedFileStore.maximumFiles,
              urls.allSatisfy({ $0.isFileURL }), x.isFinite, y.isFinite else { return false }
        busy = true
        let generation = self.generation
        let lease = URLLease(holdURLs(urls))
        self.lease = lease
        var located = false
        locate(x, y) { [weak self] accepted in
            precondition(Thread.isMainThread)
            guard !located else { return }; located = true
            guard let self else { lease.stop(); return }
            guard accepted, self.listening, !self.closed, self.generation == generation else {
                lease.stop(); self.lease = nil; self.busy = false; return
            }
            let release = self.release
            self.prepare(urls) { [weak self] result in
                precondition(Thread.isMainThread)
                // The SelectedFileStore now owns any successful URL access.
                lease.stop()
                guard let self else {
                    if case .success(let files) = result { release(files) }
                    return
                }
                self.lease = nil
                guard !self.closed, self.listening, self.generation == generation else {
                    if case .success(let files) = result { release(files) }
                    self.busy = false; return
                }
                switch result {
                case .failure:
                    self.busy = false; self.onError()
                case .success(let files):
                    self.pending = files
                    var decided = false
                    self.offer(files, x, y) { [weak self] accepted in
                        precondition(Thread.isMainThread)
                        guard !decided else { return }; decided = true
                        guard let self, !self.closed else { return }
                        // A true response owns the batch even if cancel crossed it.
                        self.finish(accepted: accepted)
                    }
                }
            }
        }
        return true
    }

    private func finish(accepted: Bool) {
        if !accepted { release(pending) }
        pending = []; busy = false
    }
    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        cancel(); closed = true; finish(accepted: false)
    }

    private final class URLLease {
        private var stopAccess: (() -> Void)?
        init(_ stop: @escaping () -> Void) { stopAccess = stop }
        func stop() { let action = stopAccess; stopAccess = nil; action?() }
        deinit { stop() }
    }
}
