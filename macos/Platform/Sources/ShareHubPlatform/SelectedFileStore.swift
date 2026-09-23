import Foundation
import Darwin

public enum SelectedFileError: Error, Equatable {
    case closed, limit, unavailable, changed, invalidRead, incomplete
    public var message: String {
        switch self {
        case .closed: return "文件访问已结束，请重新选择文件。"
        case .limit: return "一次最多保留 64 个文件，请先移除部分文件。"
        case .unavailable: return "无法读取所选文件，请选择本机可用的普通文件。"
        case .changed: return "文件在准备过程中发生变化，请重新选择。"
        case .invalidRead: return "文件读取顺序或分块大小无效。"
        case .incomplete: return "文件内容尚未完整读取。"
        }
    }
}

public enum SourceFileError: String, Error {
    case closed, resourceLimit = "resource_limit", invalidToken = "invalid_token"
    case invalidScope = "invalid_scope", invalidRead = "invalid_read"
    case sourceChanged = "source_changed", sourceIncomplete = "source_incomplete"
    case sourceUnavailable = "source_unavailable", expired, clockFailure = "clock_failure", stopped
}
public enum SourceStopMode: String { case pause, cancel }
public enum SourceStopState: String { case paused, cancelled }

public struct SelectedFileInfo {
    public let token: String
    public let name: String
    public let size: Int64
    public var dictionary: [String: Any] { ["token": token, "name": name, "size": size] }
}

/// Native picker URLs are the sole path authority. Disk methods belong on a
/// bounded worker; control/release/shutdown never wait on an entry's I/O lock.
public final class SelectedFileStore {
    public static let maximumFiles = 64
    public static let maximumChunk = 256 * 1024
    private let registry = NSLock()
    private var entries: [String: Entry] = [:]
    private var retired: [String: Entry] = [:]
    private var scopes: [String: Scope] = [:]
    private var pendingFiles = 0
    private var closed = false
    private let clock: Clock
    private let io: SelectedFileIO
    private let cleanup = DispatchQueue(label: "dev.sharehub.source.cleanup", qos: .utility)

    public var count: Int { registry.lock(); defer { registry.unlock() }; return entries.count }
    public convenience init(clock: @escaping () throws -> Int64 = { try ReceiveStore.continuousMicros() }) {
        self.init(clock: clock, io: SelectedFileIO())
    }
    internal init(clock: @escaping () throws -> Int64, io: SelectedFileIO) {
        self.clock = Clock(read: clock); self.io = io
    }

    /// Selection is atomic. Retired handles still count until worker teardown.
    public func add(_ urls: [URL]) throws -> [SelectedFileInfo] {
        registry.lock()
        guard !closed else { registry.unlock(); throw SelectedFileError.closed }
        guard urls.count <= Self.maximumFiles - entries.count - retired.count - pendingFiles else {
            registry.unlock(); throw SelectedFileError.limit
        }
        pendingFiles += urls.count
        registry.unlock()
        defer { registry.lock(); pendingFiles -= urls.count; registry.unlock() }
        var pending: [Entry] = []
        do {
            for url in urls {
                registry.lock(); let alive = !closed; registry.unlock()
                guard alive else { throw SelectedFileError.closed }
                pending.append(try Entry(url: url, clock: clock, io: io, authorizeSelection: { try self.checkSelectionOpen() }))
            }
            registry.lock()
            guard !closed else { registry.unlock(); throw SelectedFileError.closed }
            do { try clock.ensureAvailable() }
            catch { registry.unlock(); throw SelectedFileError.closed }
            for entry in pending { entries[entry.info.token] = entry }
            registry.unlock()
            return pending.map(\.info)
        } catch {
            for entry in pending { entry.retire(); entry.close() }
            throw error
        }
    }

    public func scopeOpen(token: String, key: String, deadlineMicros: Int64) throws -> String {
        guard Self.validText(token) else { throw SourceFileError.invalidToken }
        guard Self.validText(key), deadlineMicros > 0 else { throw SourceFileError.invalidScope }
        registry.lock(); defer { registry.unlock() }
        guard !closed else { throw SourceFileError.closed }
        guard let entry = entries[token] else { throw SourceFileError.invalidToken }
        entry.control.lock(); defer { entry.control.unlock() }
        guard !entry.released else { throw SourceFileError.stopped }
        guard try clock.now() < deadlineMicros else { throw SourceFileError.expired }
        if let old = entry.boundScope {
            guard old.state != .cancelled else { throw SourceFileError.stopped }
            guard old.state == .paused, old.key == key, old.deadline == deadlineMicros else { throw SourceFileError.invalidScope }
        }
        guard scopes.count < Self.maximumFiles else { throw SourceFileError.resourceLimit }
        let scope = Scope(entry: entry, key: key, deadline: deadlineMicros)
        try entry.advanceLocked()
        entry.guarded = true
        entry.passMode = true
        entry.boundScope = scope
        scopes[scope.token] = scope
        return scope.token
    }

    public func scopeStop(scope: String, mode: SourceStopMode) throws -> SourceStopState {
        registry.lock(); let selected = scopes[scope]; registry.unlock()
        guard let selected else { throw SourceFileError.invalidScope }
        guard let entry = selected.entry else { return .cancelled }
        return entry.stop(selected, mode: mode)
    }
    public func scopeClose(scope: String) {
        registry.lock(); let selected = scopes.removeValue(forKey: scope); registry.unlock()
        if let selected, let entry = selected.entry { _ = entry.stop(selected, mode: .cancel) }
    }

    public func beginPass(token: String, scope: String) throws -> String {
        try source { try begin(try find(token), scope: scope) }
    }
    public func readPass(token: String, scope: String, passId: String, offset: Int64, length: Int) throws -> Data {
        try source { try read(try find(token), scope: scope, passId: passId, offset: offset, length: length) }
    }
    public func finishPass(token: String, scope: String, passId: String) throws {
        try source { try finish(try find(token), scope: scope, passId: passId) }
    }
    public func read(token: String, offset: Int64, length: Int) throws -> Data {
        try legacy { try read(try find(token), scope: nil, passId: nil, offset: offset, length: length) }
    }
    public func finish(token: String) throws {
        try legacy { try finish(try find(token), scope: nil, passId: nil) }
    }
    public func beginReadPass(token: String) throws -> String {
        try legacy { try begin(try find(token), scope: nil) }
    }
    public func readPass(token: String, passId: String, offset: Int64, length: Int) throws -> Data {
        try legacy { try read(try find(token), scope: nil, passId: passId, offset: offset, length: length) }
    }
    public func finishPass(token: String, passId: String) throws {
        try legacy { try finish(try find(token), scope: nil, passId: passId) }
    }

    // These main-delivery gates contain no filesystem work. A result queued
    // before pause/rebind/release is not proof of current authorization.
    internal func validateSourceDelivery(token: String, scope: String, passId: String) throws {
        _ = try find(token).permit(scope: scope, passId: passId)
    }
    internal func validateLegacyDelivery(token: String, passId: String? = nil) throws {
        try legacy { _ = try find(token).permit(scope: nil, passId: passId) }
    }

    private func begin(_ entry: Entry, scope: String?) throws -> String {
        // Invalidate previous passes before waiting on another admitted read.
        let permit = try entry.begin(scope: scope)
        io.didInvalidatePass()
        entry.work.lock(); defer { entry.work.unlock() }
        try entry.validate(permit)
        try entry.authorize(permit)
        try io.rewind(entry.fd)
        try entry.validate(permit)
        entry.offset = 0
        return try entry.completeBegin(permit)
    }
    private func read(_ entry: Entry, scope: String?, passId: String?, offset: Int64, length: Int) throws -> Data {
        entry.work.lock(); defer { entry.work.unlock() }
        let permit = try entry.permit(scope: scope, passId: passId)
        guard length > 0, length <= Self.maximumChunk, offset >= 0, offset == entry.offset,
              offset < entry.info.size || (passId == nil && scope == nil && offset == entry.info.size) else {
            throw SelectedFileError.invalidRead
        }
        do {
            try entry.validate(permit)
            let size = Int(min(Int64(length), entry.info.size - offset))
            var data = Data(count: size)
            try data.withUnsafeMutableBytes { buffer in
                var used = 0
                while used < size {
                    try entry.authorize(permit)
                    let actual: Int
                    do { actual = try io.read(entry.fd, buffer: buffer.baseAddress!.advanced(by: used), count: size - used) }
                    catch is SelectedReadInterrupted { continue }
                    guard actual > 0, actual <= size - used else { throw SelectedFileError.changed }
                    used += actual
                }
            }
            try entry.validate(permit)
            try entry.authorize(permit)
            entry.offset += Int64(size)
            return data
        } catch {
            // A partially advanced cursor cannot be reused by a stale pass.
            // The next pass must reset/revalidate the original descriptor.
            entry.invalidate(permit)
            throw error
        }
    }
    private func finish(_ entry: Entry, scope: String?, passId: String?) throws {
        entry.work.lock(); defer { entry.work.unlock() }
        let permit = try entry.permit(scope: scope, passId: passId)
        try entry.validate(permit)
        guard entry.offset == entry.info.size else { throw SelectedFileError.incomplete }
        try entry.authorize(permit)
    }

    public func release(token: String) {
        registry.lock()
        guard let entry = entries.removeValue(forKey: token) else { registry.unlock(); return }
        retired[token] = entry
        entry.retire()
        registry.unlock()
        enqueueClose(entry)
    }
    public func shutdown() {
        registry.lock()
        guard !closed else { registry.unlock(); return }
        closed = true
        let selected = Array(entries.values)
        for entry in selected { retired[entry.info.token] = entry; entry.retire() }
        entries.removeAll(); scopes.removeAll()
        registry.unlock()
        for entry in selected { enqueueClose(entry) }
    }
    private func enqueueClose(_ entry: Entry) {
        cleanup.async { [weak self] in
            entry.close()
            if let self {
                self.registry.lock(); self.retired.removeValue(forKey: entry.info.token); self.registry.unlock()
            }
        }
    }
    deinit {
        for entry in entries.values { entry.retire(); cleanup.async { entry.close() } }
        // Already retired entries have one pending cleanup closure each.
    }

    private func find(_ token: String) throws -> Entry {
        registry.lock(); defer { registry.unlock() }
        guard !closed else { throw SourceFileError.closed }
        guard let entry = entries[token] else { throw SourceFileError.invalidToken }
        return entry
    }
    private func checkSelectionOpen() throws {
        registry.lock(); defer { registry.unlock() }
        guard !closed else { throw SelectedFileError.closed }
        do { try clock.ensureAvailable() } catch { throw SelectedFileError.closed }
    }
    private static func validText(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && !value.utf8.contains(0) }
    private func legacy<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as SourceFileError {
            if error == .closed || error == .invalidToken || error == .stopped || error == .clockFailure { throw SelectedFileError.closed }
            throw SelectedFileError.invalidRead
        }
    }
    private func source<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as SelectedFileError {
            switch error {
            case .closed: throw SourceFileError.closed
            case .limit: throw SourceFileError.resourceLimit
            case .unavailable: throw SourceFileError.sourceUnavailable
            case .changed: throw SourceFileError.sourceChanged
            case .invalidRead: throw SourceFileError.invalidRead
            case .incomplete: throw SourceFileError.sourceIncomplete
            }
        }
    }

    private final class Clock {
        private let lock = NSLock()
        private let read: () throws -> Int64
        private var last: Int64 = 0
        private var failed = false
        init(read: @escaping () throws -> Int64) { self.read = read }
        func ensureAvailable() throws {
            lock.lock(); defer { lock.unlock() }
            guard !failed else { throw SourceFileError.clockFailure }
        }
        func now() throws -> Int64 {
            lock.lock(); defer { lock.unlock() }
            guard !failed else { throw SourceFileError.clockFailure }
            do {
                let value = try read()
                guard value > 0, value >= last else { throw SourceFileError.clockFailure }
                last = value
                return value
            } catch { failed = true; throw SourceFileError.clockFailure }
        }
    }
    private final class Scope {
        enum State { case active, paused, cancelled }
        let token = UUID().uuidString.lowercased()
        weak var entry: Entry?
        let key: String
        let deadline: Int64
        // State is protected by the associated entry's control lock.
        var state = State.active
        init(entry: Entry, key: String, deadline: Int64) { self.entry = entry; self.key = key; self.deadline = deadline }
    }
    private struct Permit {
        let generation: UInt64
        let scope: Scope?
        let passId: String?
    }

    private final class Entry {
        let work = NSLock(), control = NSLock()
        let info: SelectedFileInfo
        let url: URL
        let original: stat
        let clock: Clock
        let io: SelectedFileIO
        var fd: Int32
        var offset: Int64 = 0 // work lock
        private var securityScoped: Bool
        // All following fields use control, including scope state.
        var released = false
        var guarded = false
        var passMode = false
        var passId: String?
        var generation: UInt64 = 0
        var boundScope: Scope?

        init(url: URL, clock: Clock, io: SelectedFileIO, authorizeSelection: () throws -> Void) throws {
            guard url.isFileURL else { throw SelectedFileError.unavailable }
            try authorizeSelection()
            let scoped = url.startAccessingSecurityScopedResource()
            let descriptor: Int32
            do {
                try authorizeSelection()
                descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            guard descriptor >= 0 else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw SelectedFileError.unavailable
            }
            let snapshot: stat
            do { try authorizeSelection(); snapshot = try io.snapshot(descriptor); try authorizeSelection() }
            catch {
                io.close(descriptor)
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            guard snapshot.st_mode & S_IFMT == S_IFREG, snapshot.st_size >= 0 else {
                io.close(descriptor)
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw SelectedFileError.unavailable
            }
            self.url = url; self.clock = clock; self.io = io
            securityScoped = scoped; fd = descriptor; original = snapshot
            info = SelectedFileInfo(token: UUID().uuidString.lowercased(), name: url.lastPathComponent, size: snapshot.st_size)
        }

        func advanceLocked() throws {
            guard generation < UInt64.max else { throw SourceFileError.resourceLimit }
            generation += 1; passId = nil
        }
        private func checkLocked(_ scope: Scope?) throws {
            guard !released else { throw SourceFileError.stopped }
            if let scope {
                guard boundScope === scope else { throw SourceFileError.invalidScope }
                guard scope.state == .active else { throw SourceFileError.stopped }
                guard try clock.now() < scope.deadline else { throw SourceFileError.expired }
            } else {
                guard !guarded else { throw SourceFileError.invalidScope }
                // Local preparation needs no grant/clock sample, but a prior
                // observed clock failure poisons all store I/O permanently.
                try clock.ensureAvailable()
            }
        }
        private func selectedScopeLocked(_ token: String?) throws -> Scope? {
            guard let token else { return nil }
            guard let current = boundScope, current.token == token else { throw SourceFileError.invalidScope }
            return current
        }
        func begin(scope: String?) throws -> Permit {
            control.lock(); defer { control.unlock() }
            let selected = try selectedScopeLocked(scope)
            try checkLocked(selected)
            try advanceLocked()
            passMode = true
            return Permit(generation: generation, scope: selected, passId: nil)
        }
        func permit(scope: String?, passId: String?) throws -> Permit {
            control.lock(); defer { control.unlock() }
            let selected = try selectedScopeLocked(scope)
            try checkLocked(selected)
            if let passId {
                guard !passId.isEmpty, self.passId == passId else { throw SourceFileError.invalidRead }
            } else { guard !passMode, selected == nil else { throw SourceFileError.invalidRead } }
            return Permit(generation: generation, scope: selected, passId: passId)
        }
        func authorize(_ permit: Permit) throws {
            control.lock(); defer { control.unlock() }
            try checkLocked(permit.scope)
            guard generation == permit.generation, passId == permit.passId else { throw SourceFileError.invalidRead }
        }
        func completeBegin(_ permit: Permit) throws -> String {
            control.lock(); defer { control.unlock() }
            try checkLocked(permit.scope)
            guard generation == permit.generation, passId == nil else { throw SourceFileError.invalidRead }
            let created = UUID().uuidString.lowercased()
            passId = created
            return created
        }
        func invalidate(_ permit: Permit) {
            control.lock(); defer { control.unlock() }
            if generation == permit.generation { passId = nil; passMode = true; if generation < UInt64.max { generation += 1 } }
        }
        func stop(_ scope: Scope, mode: SourceStopMode) -> SourceStopState {
            control.lock(); defer { control.unlock() }
            if released || scope.state == .cancelled { scope.state = .cancelled; return .cancelled }
            scope.state = mode == .pause ? .paused : .cancelled
            return mode == .pause ? .paused : .cancelled
        }
        func retire() { control.lock(); released = true; boundScope?.state = .cancelled; passId = nil; control.unlock() }
        func validate(_ permit: Permit) throws {
            try authorize(permit)
            let descriptorState = try io.snapshot(fd)
            try authorize(permit)
            let pathState = try io.pathSnapshot(url)
            try authorize(permit)
            guard matches(descriptorState), matches(pathState) else { throw SelectedFileError.changed }
        }
        private func matches(_ value: stat) -> Bool {
            value.st_dev == original.st_dev && value.st_ino == original.st_ino &&
            value.st_size == original.st_size && value.st_mode & S_IFMT == S_IFREG &&
            value.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec &&
            value.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        }
        func close() {
            work.lock(); defer { work.unlock() }
            guard fd >= 0 else { return }
            io.close(fd); fd = -1
            if securityScoped { url.stopAccessingSecurityScopedResource(); securityScoped = false }
        }
        deinit { close() }
    }
}

/// Internal deterministic syscall seam. Data uses original fds; the known
/// picker URL is lstat'ed for identity and is never reopened for reading.
internal class SelectedFileIO {
    func didInvalidatePass() {}
    func snapshot(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw SelectedFileError.changed }
        return value
    }
    func pathSnapshot(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw SelectedFileError.changed }
        return value
    }
    func rewind(_ fd: Int32) throws {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw SelectedFileError.changed }
    }
    func read(_ fd: Int32, buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let actual = Darwin.read(fd, buffer, count)
        if actual < 0 && errno == EINTR { throw SelectedReadInterrupted() }
        guard actual >= 0 else { throw SelectedFileError.unavailable }
        return actual
    }
    func close(_ fd: Int32) { Darwin.close(fd) }
}

internal struct SelectedReadInterrupted: Error {}
