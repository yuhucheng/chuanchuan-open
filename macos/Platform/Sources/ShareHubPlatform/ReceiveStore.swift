import CryptoKit
import Darwin
import Foundation
import Security

public enum ReceiveStoreError: String, Error {
    case invalidToken = "invalid_token", staleScope = "stale_scope"
    case invalidName = "invalid_name", invalidRange = "invalid_range"
    case resourceLimit = "resource_limit", unsupportedStorage = "unsupported_storage"
    case directoryChanged = "directory_changed", sourceChanged = "source_changed"
    case integrityMismatch = "integrity_mismatch", permissionDenied = "permission_denied"
    case diskFull = "disk_full", ioFailure = "io_failure"
    case cancelled, paused, expired, clockUnavailable = "clock_unavailable"
    case nameExhausted = "name_exhausted", cleanupFailed = "cleanup_failed"
    case settingsUnavailable = "settings_unavailable"
}

fileprivate struct ReceiveDirectoryRecord: Codable {
    let version: Int
    let path: String
    let identity: String
    let bookmark: Data
}

/// Local destination preference only. Contains no transfer, grant, token or
/// unfinished-file journal. The file URL is supplied only by native hosts/tests.
public final class ReceiveDirectoryPreferences {
    private let file: URL?
    public init(file: URL? = nil) { self.file = file }

    private func location() throws -> URL {
        if let file { return file }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("dev.sharehub.client", isDirectory: true)
            .appendingPathComponent("receive-directory-v1.plist")
    }

    fileprivate func load() throws -> ReceiveDirectoryRecord? {
        do {
            let fd = Darwin.open(try location().path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                if errno == ENOENT { return nil }
                throw ReceiveStoreError.settingsUnavailable
            }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_size > 0, info.st_size <= 131_072 else {
                throw ReceiveStoreError.settingsUnavailable
            }
            var data = Data(count: Int(info.st_size))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ReceiveStoreError.settingsUnavailable }
                    offset += count
                }
            }
            var extra: UInt8 = 0
            guard Darwin.read(fd, &extra, 1) == 0 else { throw ReceiveStoreError.settingsUnavailable }
            let record = try PropertyListDecoder().decode(ReceiveDirectoryRecord.self, from: data)
            guard record.version == 1, !record.bookmark.isEmpty, record.bookmark.count <= 65_536,
                  record.path.utf8.count <= 32_767, !record.identity.isEmpty else {
                throw ReceiveStoreError.settingsUnavailable
            }
            return record
        } catch { throw ReceiveStoreError.settingsUnavailable }
    }

    fileprivate func save(_ record: ReceiveDirectoryRecord) throws {
        do {
            let destination = try location()
            let data = try PropertyListEncoder().encode(record)
            guard data.count <= 131_072, record.bookmark.count <= 65_536 else {
                throw ReceiveStoreError.settingsUnavailable
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: destination, options: .atomic)
        } catch { throw ReceiveStoreError.settingsUnavailable }
    }
}

public enum ReceiveStopMode: String { case pause, cancel }
public enum ReceiveStopState: String { case paused, cancelled, committing, committed }

public struct ReceiveDirectory {
    public let token: String
    public let label: String
    public var dictionary: [String: Any] { ["token": token, "label": label] }
}

public struct ReceiveCheckpoint: Equatable {
    public let offset: Int64
    public let sha256: String
    public let identity: String
    public init(offset: Int64, sha256: String, identity: String) {
        self.offset = offset; self.sha256 = sha256; self.identity = identity
    }
    public var dictionary: [String: Any] { ["offset": offset, "sha256": sha256, "identity": identity] }
}

public struct ReceiveReceipt: Equatable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public var dictionary: [String: Any] { ["name": name, "size": size, "sha256": sha256] }
}

/// Receives only into directories issued by native picker / OS Downloads APIs.
/// Paths, descriptors and filesystem identities are never channel results.
///
/// Call I/O methods on a bounded worker executor. Each entry serializes its
/// work; unrelated entries can run concurrently. scopeStop, abort and shutdown
/// only take short control locks and never wait for an entry's hash / I/O lock.
/// An I/O admitted by the control gate may finish after a stop; another I/O
/// cannot be admitted. The publish gate changes active -> committing before
/// rename, so a stop never reports cancelled after publication has won.
///
/// Directory authority is tied to retained objects. Observed ancestry moves
/// or replacements fail closed. POSIX cannot freeze ancestors or atomically
/// compare an inode while renaming/unlinking its name; a hostile local process
/// with the same user's privileges is outside this isolation boundary.
public final class ReceiveStore {
    public static let maximumEntries = 64
    public static let maximumChunk = 32_768
    private let registry = NSLock()
    private var directories: [String: Directory] = [:]
    private var scopes: [String: Scope] = [:]
    private var entries: [String: Entry] = [:]
    private var pendingEntries = 0
    private var closed = false
    private let clock: Clock
    private let ledger: Reservations
    private let fileSystem: ReceiveStoreFileSystem
    private let preferences: ReceiveDirectoryPreferences?
    private let directorySettings = NSLock()
    private let cleanupQueue = DispatchQueue(label: "dev.sharehub.receive.cleanup", qos: .utility)

    public convenience init(
        clock: @escaping () throws -> Int64 = { try ReceiveStore.continuousMicros() },
        maximumReservedBytes: Int64? = nil,
        preferences: ReceiveDirectoryPreferences? = nil
    ) {
        self.init(clock: clock, maximumReservedBytes: maximumReservedBytes, fileSystem: ReceiveStoreFileSystem(), preferences: preferences)
    }

    internal init(clock: @escaping () throws -> Int64, maximumReservedBytes: Int64? = nil, fileSystem: ReceiveStoreFileSystem, preferences: ReceiveDirectoryPreferences? = nil) {
        self.clock = Clock(read: clock)
        ledger = Reservations(maximum: maximumReservedBytes)
        self.fileSystem = fileSystem
        self.preferences = preferences
    }

    /// Same continuous, sleep-inclusive time domain as ConnectionSecurity.
    /// Full-width arithmetic avoids both floating-point rounding and overflow.
    public static func continuousMicros() throws -> Int64 {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            throw ReceiveStoreError.clockUnavailable
        }
        let divisor = UInt64(info.denom) * 1_000
        let product = mach_continuous_time().multipliedFullWidth(by: UInt64(info.numer))
        guard product.high < divisor else { throw ReceiveStoreError.clockUnavailable }
        let micros = divisor.dividingFullWidth(product).quotient
        guard micros > 0, micros <= UInt64(Int64.max) else { throw ReceiveStoreError.clockUnavailable }
        return Int64(micros)
    }

    public func directoryDefault() throws -> ReceiveDirectory {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ReceiveStoreError.permissionDenied
        }
        let directory = try Directory(url: url)
        try directory.createAndOpenChild("串串")
        return try register(directory)
    }

    /// Only native picker results may call this; never expose a path argument
    /// on the Flutter channel. Every component, including ancestors, is nofollow.
    public func directoryFromPicker(_ url: URL) throws -> ReceiveDirectory {
        directorySettings.lock(); defer { directorySettings.unlock() }
        let directory = try Directory(url: url)
        let result = try register(directory)
        do {
            if let preferences {
                let bookmark = try url.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                try directory.validate()
                try preferences.save(ReceiveDirectoryRecord(version: 1, path: url.standardizedFileURL.path,
                    identity: try directory.persistentIdentity(), bookmark: bookmark))
            }
            return result
        } catch {
            directoryRelease(token: result.token)
            throw ReceiveStoreError.settingsUnavailable
        }
    }

    public func directoryConfigured() throws -> ReceiveDirectory {
        directorySettings.lock(); defer { directorySettings.unlock() }
        guard let record = try preferences?.load() else { return try directoryDefault() }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: record.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw ReceiveStoreError.directoryChanged }
        guard !stale, url.standardizedFileURL.path == record.path else { throw ReceiveStoreError.directoryChanged }
        let directory = try Directory(url: url)
        guard try directory.persistentIdentity() == record.identity else { throw ReceiveStoreError.directoryChanged }
        return try register(directory)
    }

    private func register(_ directory: Directory) throws -> ReceiveDirectory {
        try directory.validate()
        try fileSystem.requireSupportedVolume(directory.fd)
        let token = try Self.randomToken()
        registry.lock(); defer { registry.unlock() }
        guard !closed else { throw ReceiveStoreError.cancelled }
        guard directories.count < Self.maximumEntries else { throw ReceiveStoreError.resourceLimit }
        directories[token] = directory
        return ReceiveDirectory(token: token, label: directory.label)
    }

    public func directoryRelease(token: String) {
        registry.lock(); let removed = directories.removeValue(forKey: token); registry.unlock()
        // An entry still retains this directory and its security scope.
        withExtendedLifetime(removed) {}
    }

    public func scopeOpen(key: String, deadlineMicros: Int64) throws -> String {
        guard !key.isEmpty, key.utf8.count <= 256, !key.utf8.contains(0), deadlineMicros > 0 else {
            throw ReceiveStoreError.invalidRange
        }
        guard try clock.now() < deadlineMicros else { throw ReceiveStoreError.expired }
        let token = try Self.randomToken()
        let scope = Scope(token: token, key: key, deadline: deadlineMicros, clock: clock)
        registry.lock(); defer { registry.unlock() }
        guard !closed else { throw ReceiveStoreError.cancelled }
        guard scopes.count < Self.maximumEntries else { throw ReceiveStoreError.resourceLimit }
        scopes[token] = scope
        return token
    }

    @discardableResult
    public func scopeStop(scope: String, mode: ReceiveStopMode) throws -> ReceiveStopState {
        let permit = try findScope(scope)
        let result = permit.stop(mode)
        if mode == .cancel { enqueueCleanupForScope(permit) }
        return result
    }

    public func scopeClose(scope: String) {
        registry.lock(); let removed = scopes.removeValue(forKey: scope); registry.unlock()
        if let removed {
            _ = removed.stop(.cancel)
            enqueueCleanupForScope(removed)
        }
        // Entries retain their guards even when the public scope is released.
    }

    public func begin(directory: String, scope: String, name: String, size: Int64, sha256: String) throws -> String {
        try? retryPendingCleanup()
        let safeName = try Self.validateName(name)
        guard size >= 0, Self.validHash(sha256) else { throw ReceiveStoreError.invalidRange }
        registry.lock()
        guard !closed, let destination = directories[directory], let permit = scopes[scope] else {
            registry.unlock(); throw ReceiveStoreError.invalidToken
        }
        guard entries.count + pendingEntries < Self.maximumEntries else {
            registry.unlock(); throw ReceiveStoreError.resourceLimit
        }
        pendingEntries += 1
        registry.unlock()
        defer { registry.lock(); pendingEntries -= 1; registry.unlock() }
        try permit.claim()
        try permit.check()
        try destination.validate()
        let reservation = try ledger.reserve(size: size, directory: destination, fileSystem: fileSystem)
        var entry: Entry?
        // Function-scoped so cleanup cannot close the descriptor between the
        // final authorization failure and catch marking it as unreturned.
        defer { entry?.work.unlock() }
        do {
            try permit.check()
            let created = try Entry(directory: destination, scope: permit, name: safeName, size: size,
                                    sha256: sha256, reservation: reservation)
            created.work.lock()
            entry = created
            try created.createFile(fileSystem: fileSystem)
            try permit.check()
            registry.lock()
            if closed {
                registry.unlock(); throw ReceiveStoreError.cancelled
            }
            entries[created.token] = created
            registry.unlock()
            fileSystem.didRegisterTemporary(work: created.work)
            // A cancel can precede registration and therefore miss the scope's
            // cleanup snapshot. Recheck once it is visible so either this path
            // or the cancelling caller owns the asynchronous cleanup request.
            try permit.check()
            return created.token
        } catch {
            if let entry, entry.fd >= 0 {
                entry.unreturned = true
                entry.requestAbort()
                // Keep a failed exact-object cleanup record even if creation
                // raced shutdown; never discard the original descriptor.
                registry.lock(); entries[entry.token] = entry; registry.unlock()
                enqueueCleanup(entry)
            } else { reservation.release() }
            throw Self.translate(error)
        }
    }

    @discardableResult
    public func append(token: String, scope: String, offset: Int64, bytes: Data) throws -> Int64 {
        let entry = try findEntry(token)
        entry.work.lock(); defer { entry.work.unlock() }
        let permit = try entry.requireReceiving(scope)
        do {
            guard offset == entry.offset, offset >= 0, !bytes.isEmpty, bytes.count <= Self.maximumChunk,
                  offset <= entry.size, Int64(bytes.count) <= entry.size - offset else {
                throw ReceiveStoreError.invalidRange
            }
            try entry.authorize(permit)
            try entry.directory.validate()
            try entry.validateFile(expectedSize: entry.offset, unchanged: entry.lastState)
            try bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < buffer.count {
                    try entry.authorize(permit)
                    let count: Int
                    do {
                        count = try fileSystem.write(entry.fd, bytes: buffer.baseAddress!.advanced(by: written),
                                                     count: buffer.count - written, offset: entry.offset)
                    } catch let error as ReceiveStoreSystemError where error.number == EINTR { continue }
                    guard count > 0, count <= buffer.count - written else { throw ReceiveStoreError.ioFailure }
                    entry.prefix.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[written..<(written + count)]))
                    written += count
                    entry.offset += Int64(count)
                    entry.reservation.consume(Int64(count))
                    // Cache every successfully written prefix, even when the
                    // next partial write is stopped or fails.
                    entry.lastState = try entry.validateFile(expectedSize: entry.offset)
                }
            }
            try entry.authorize(permit)
            return entry.offset
        } catch {
            let failure = Self.translate(error)
            fail(entry, error: failure)
            throw failure
        }
    }

    /// No filesystem reads: a paused caller gets the cached successful prefix.
    public func checkpoint(token: String) throws -> ReceiveCheckpoint {
        let entry = try findEntry(token)
        entry.work.lock(); defer { entry.work.unlock() }
        guard entry.phase == .receiving, !entry.isAborted else { throw ReceiveStoreError.cancelled }
        let state = entry.scope.currentState
        guard state == .active || state == .paused else { throw ReceiveStoreError.cancelled }
        return entry.checkpoint
    }

    public func resume(token: String, scope: String, checkpoint: ReceiveCheckpoint) throws {
        let entry = try findEntry(token)
        let next = try findScope(scope)
        entry.work.lock(); defer { entry.work.unlock() }
        let previous = entry.scope
        guard entry.phase == .receiving, previous.currentState == .paused, !entry.isAborted,
              next.token != previous.token, next.key == entry.originalKey,
              next.deadline == entry.originalDeadline else { throw ReceiveStoreError.staleScope }
        do {
            guard checkpoint == entry.checkpoint else { throw ReceiveStoreError.integrityMismatch }
            try next.claim()
            let authorize = {
                guard previous.currentState == .paused else { throw ReceiveStoreError.cancelled }
                try entry.authorize(next)
            }
            let (hash, snapshot) = try hashOriginal(entry, length: checkpoint.offset, authorize: authorize)
            guard hash == checkpoint.sha256 else { throw ReceiveStoreError.integrityMismatch }
            try authorize()
            try entry.directory.validate()
            try entry.validateFile(expectedSize: checkpoint.offset, unchanged: snapshot)
            // Cancellation of either scope / abort must still win a race with
            // the final rebinding. Holding these short locks performs no I/O.
            entry.control.lock(); defer { entry.control.unlock() }
            guard !entry.aborted else { throw ReceiveStoreError.cancelled }
            try previous.withPaused {
                try next.check()
                entry.boundScope = next
            }
            entry.lastState = snapshot
        } catch {
            let failure = Self.translate(error)
            fail(entry, error: failure)
            throw failure
        }
    }

    public func commit(token: String, scope: String) throws -> ReceiveReceipt {
        let entry = try findEntry(token)
        entry.work.lock(); defer { entry.work.unlock() }
        // Receipt replay is permitted only for the same scope and actual commit.
        if let receipt = entry.receipt, entry.scope.token == scope { return receipt }
        let permit = try entry.requireReceiving(scope)
        do {
            guard entry.offset == entry.size else { throw ReceiveStoreError.invalidRange }
            let (hash, snapshot) = try hashOriginal(entry, length: entry.size) { try entry.authorize(permit) }
            guard hash == entry.expectedHash else { throw ReceiveStoreError.integrityMismatch }
            try entry.authorize(permit)
            try fileSystem.synchronize(entry.fd)
            try entry.authorize(permit)
            try entry.directory.validate()
            try entry.validateFile(expectedSize: entry.size, unchanged: snapshot)
            // This is the only publication linearization point. No registry or
            // scope mutex stays held across the OS rename (which may block).
            try entry.winPublish(permit)
            for index in 0..<1_000 {
                try permit.check(publishing: true)
                try entry.directory.validate()
                try entry.validateFile(expectedSize: entry.size, unchanged: snapshot)
                let name = Self.candidate(entry.name, index: index)
                do {
                    try fileSystem.rename(directory: entry.directory.fd, from: entry.temporaryName, to: name)
                } catch let error as ReceiveStoreSystemError where error.number == EEXIST { continue }
                // Once rename succeeds, no fallible post-publish operation can
                // turn this into a cancellation or delete the completed file.
                let receipt = ReceiveReceipt(name: name, size: entry.size, sha256: hash)
                entry.receipt = receipt
                entry.phase = .committed
                entry.closeDescriptor()
                entry.reservation.release()
                permit.didCommit()
                return receipt
            }
            throw ReceiveStoreError.nameExhausted
        } catch {
            let failure = Self.translate(error)
            fail(entry, error: failure)
            throw failure
        }
    }

    /// Immediate stop barrier; exact-object cleanup happens off the caller.
    public func abort(token: String) {
        guard let entry = try? findEntry(token, allowClosed: true) else { return }
        entry.requestAbort()
        enqueueCleanup(entry)
    }

    /// Worker method. Failed cleanup retains the fd and identity for retry.
    public func retryCleanup(token: String) throws {
        guard let entry = try? findEntry(token, allowClosed: true) else { return }
        try Self.cleanup(entry, fileSystem: fileSystem)
    }

    /// Worker-only bounded retry of known terminal objects, including failed
    /// begin calls whose token was never exposed. No filesystem enumeration.
    public func retryPendingCleanup() throws {
        registry.lock(); let candidates = Array(entries.values); registry.unlock()
        var failed = false
        for entry in candidates {
            guard entry.isAborted || entry.scope.currentState == .cancelled else { continue }
            do {
                let unreturned = try Self.cleanup(entry, fileSystem: fileSystem)
                if unreturned {
                    registry.lock(); entries.removeValue(forKey: entry.token); registry.unlock()
                }
            } catch { failed = true }
        }
        if failed { throw ReceiveStoreError.cleanupFailed }
    }

    /// Drop bounded receipt/terminal metadata without deleting committed data.
    /// Incomplete entries must first be aborted and successfully cleaned.
    public func release(token: String) throws {
        guard let entry = try? findEntry(token, allowClosed: true) else { return }
        entry.work.lock(); defer { entry.work.unlock() }
        guard entry.phase == .committed || entry.phase == .cleaned else { throw ReceiveStoreError.invalidRange }
        registry.lock(); entries.removeValue(forKey: token); registry.unlock()
    }

    public func shutdown() {
        registry.lock()
        guard !closed else { registry.unlock(); return }
        closed = true
        let allScopes = Array(scopes.values)
        let allEntries = Array(entries.values)
        scopes.removeAll()
        let allDirectories = directories
        directories.removeAll()
        registry.unlock()
        for scope in allScopes { _ = scope.stop(.cancel) }
        for entry in allEntries { entry.requestAbort(); enqueueCleanup(entry) }
        cleanupQueue.async { withExtendedLifetime(allDirectories) {} }
    }

    deinit {
        // Closures capture owned objects, never self. The store can deinitialize
        // without reviving itself or blocking UI on filesystem cleanup.
        for scope in scopes.values { _ = scope.stop(.cancel) }
        for entry in entries.values { entry.requestAbort(); enqueueCleanup(entry) }
        let allDirectories = directories
        cleanupQueue.async { withExtendedLifetime(allDirectories) {} }
    }

    private func findScope(_ token: String) throws -> Scope {
        registry.lock(); defer { registry.unlock() }
        guard !closed, let scope = scopes[token] else { throw ReceiveStoreError.staleScope }
        return scope
    }

    private func findEntry(_ token: String, allowClosed: Bool = false) throws -> Entry {
        registry.lock(); defer { registry.unlock() }
        guard (!closed || allowClosed), let entry = entries[token] else { throw ReceiveStoreError.invalidToken }
        return entry
    }

    private func hashOriginal(_ entry: Entry, length: Int64, authorize: () throws -> Void) throws -> (String, stat) {
        try authorize()
        try entry.directory.validate()
        let before = try entry.validateFile(expectedSize: length, unchanged: entry.lastState)
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var position: Int64 = 0
        while position < length {
            try authorize()
            let count = Int(min(Int64(buffer.count), length - position))
            let actual: Int
            do {
                actual = try buffer.withUnsafeMutableBytes {
                    try fileSystem.read(entry.fd, bytes: $0.baseAddress!, count: count, offset: position)
                }
            } catch let error as ReceiveStoreSystemError where error.number == EINTR { continue }
            guard actual > 0, actual <= count else { throw ReceiveStoreError.sourceChanged }
            buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<actual])) }
            position += Int64(actual)
        }
        try authorize()
        try entry.directory.validate()
        let after = try entry.validateFile(expectedSize: length, unchanged: before)
        return (Self.hex(digest.finalize()), after)
    }

    private func fail(_ entry: Entry, error: ReceiveStoreError) {
        if error == .paused { return }
        entry.phase = .failed
        entry.scope.didFail(error)
        entry.requestAbort()
        enqueueCleanup(entry)
    }

    private func enqueueCleanup(_ entry: Entry) {
        // Bound queued work to one cleanup operation per bounded entry.
        entry.control.lock()
        if entry.cleanupQueued { entry.control.unlock(); return }
        entry.cleanupQueued = true
        entry.control.unlock()
        let io = fileSystem
        cleanupQueue.async { [weak self] in
            defer { entry.control.lock(); entry.cleanupQueued = false; entry.control.unlock() }
            do {
                let unreturned = try Self.cleanup(entry, fileSystem: io)
                if unreturned, let self {
                    self.registry.lock()
                    self.entries.removeValue(forKey: entry.token)
                    self.registry.unlock()
                }
                io.didFinishCleanup()
            } catch {
                // Preserve the original object in the registry for a retry.
            }
        }
    }

    private func enqueueCleanupForScope(_ scope: Scope) {
        registry.lock(); let candidates = Array(entries.values); registry.unlock()
        for entry in candidates where entry.scope === scope { enqueueCleanup(entry) }
    }

    @discardableResult
    private static func cleanup(_ entry: Entry, fileSystem: ReceiveStoreFileSystem) throws -> Bool {
        entry.work.lock(); defer { entry.work.unlock() }
        guard entry.phase != .committed, entry.phase != .cleaned else { return entry.unreturned }
        guard entry.isAborted || entry.phase == .failed || entry.scope.currentState == .cancelled else {
            throw ReceiveStoreError.invalidRange
        }
        entry.phase = .failed
        do {
            // An ancestor rename does not authorize deleting its replacement.
            // Only the original fd-relative leaf with matching inode is removed.
            try entry.directory.validateObject()
            var opened = stat()
            guard entry.fd >= 0, fstat(entry.fd, &opened) == 0 else {
                throw ReceiveStoreError.cleanupFailed
            }
            entry.captureOriginalIfMissing(opened)
            guard entry.sameIdentity(opened) else { throw ReceiveStoreError.cleanupFailed }
            var named = stat()
            if fstatat(entry.directory.fd, entry.temporaryName, &named, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT, opened.st_nlink == 0 else { throw ReceiveStoreError.cleanupFailed }
            } else {
                guard entry.sameIdentity(named), opened.st_nlink == 1, named.st_nlink == 1 else {
                    throw ReceiveStoreError.cleanupFailed
                }
                try fileSystem.unlink(directory: entry.directory.fd, name: entry.temporaryName)
            }
            entry.closeDescriptor()
            entry.reservation.release()
            entry.phase = .cleaned
            // Read while holding the same work lock used by begin's failure
            // bookkeeping. Even an earlier coalesced cleanup request removes
            // metadata for a token that begin never exposed.
            return entry.unreturned
        } catch { throw ReceiveStoreError.cleanupFailed }
    }

    private static func validateName(_ value: String) throws -> String {
        let name = value.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255, name.utf16.count <= 255,
              !name.hasSuffix("."), !name.hasSuffix(" "),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || "/\\:<>\"|?*".unicodeScalars.contains($0) }) else {
            throw ReceiveStoreError.invalidName
        }
        let stem = String(name.split(separator: ".", omittingEmptySubsequences: false)[0]).uppercased()
        let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        if reserved.contains(stem) || (stem.count == 4 && (stem.hasPrefix("COM") || stem.hasPrefix("LPT")) && "123456789¹²³".contains(stem.last!)) {
            throw ReceiveStoreError.invalidName
        }
        return name
    }

    private static func candidate(_ name: String, index: Int) -> String {
        if index == 0 { return name }
        let dot = name.lastIndex(of: ".")
        let split = dot != name.startIndex ? dot : nil
        var stem = split.map { String(name[..<$0]) } ?? name
        var ext = split.map { String(name[$0...]) } ?? ""
        let suffix = " (\(index))"
        // Keep at least one stem character. Trim graphemes safely to reserve
        // UTF-8 and UTF-16 space, even for a very long extension or emoji name.
        while !ext.isEmpty && ((String(stem.prefix(1)) + suffix + ext).utf8.count > 255 || (String(stem.prefix(1)) + suffix + ext).utf16.count > 255) { ext.removeLast() }
        while (stem + suffix + ext).utf8.count > 255 || (stem + suffix + ext).utf16.count > 255 { stem.removeLast() }
        return stem + suffix + ext
    }

    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ReceiveStoreError.ioFailure }
        return hex(bytes)
    }

    /// Conservative namespace policy: deny-only ACLs are safe, but allow ACLs
    /// may bypass BSD modes or be inherited by an otherwise 0600 temporary.
    /// Inspect retained fds, never rewrite the user's permissions or reopen.
    private static func requireNoAllowACL(_ fd: Int32) throws {
        guard let security = filesec_init() else { throw ReceiveStoreError.unsupportedStorage }
        defer { filesec_free(security) }
        var info = stat()
        var present: Int32 = 0
        guard fstatx_np(fd, &info, security) == 0,
              filesec_query_property(security, FILESEC_ACL, &present) == 0 else { throw ReceiveStoreError.unsupportedStorage }
        guard present != 0 else { return }
        var copied: acl_t?
        guard filesec_get_property(security, FILESEC_ACL, &copied) == 0, let acl = copied else {
            throw ReceiveStoreError.unsupportedStorage
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, selector, &entry) == 0 {
            guard let entry else { throw ReceiveStoreError.unsupportedStorage }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                throw ReceiveStoreError.unsupportedStorage
            }
            selector = ACL_NEXT_ENTRY.rawValue
        }
        // Darwin reports EINVAL at the end of a valid ACL iteration.
        guard errno == EINVAL else { throw ReceiveStoreError.unsupportedStorage }
    }

    fileprivate static func translate(_ error: Error) -> ReceiveStoreError {
        if let error = error as? ReceiveStoreError { return error }
        guard let error = error as? ReceiveStoreSystemError else { return .ioFailure }
        switch error.number {
        case ENOSPC, EDQUOT: return .diskFull
        case EACCES, EPERM, EROFS: return .permissionDenied
        case ENOTSUP, ENOSYS, EXDEV: return .unsupportedStorage
        default: return .ioFailure
        }
    }

    private final class Clock {
        private let lock = NSLock()
        private let read: () throws -> Int64
        private var last: Int64 = 0
        private var unavailable = false
        init(read: @escaping () throws -> Int64) { self.read = read }
        func now() throws -> Int64 {
            lock.lock(); defer { lock.unlock() }
            guard !unavailable else { throw ReceiveStoreError.clockUnavailable }
            do {
                let now = try read()
                guard now > 0, now >= last else { throw ReceiveStoreError.clockUnavailable }
                last = now
                return now
            } catch {
                unavailable = true
                throw ReceiveStoreError.clockUnavailable
            }
        }
    }

    private final class Scope {
        enum State { case active, paused, cancelled, committing, committed }
        let token: String
        let key: String
        let deadline: Int64
        private let clock: Clock
        private let lock = NSLock()
        private var state = State.active
        private var claimed = false
        private var failure: ReceiveStoreError = .cancelled
        init(token: String, key: String, deadline: Int64, clock: Clock) {
            self.token = token; self.key = key; self.deadline = deadline; self.clock = clock
        }
        var currentState: State { lock.lock(); defer { lock.unlock() }; return state }
        func claim() throws {
            lock.lock(); defer { lock.unlock() }
            try checkLocked()
            guard !claimed else { throw ReceiveStoreError.staleScope }
            claimed = true
        }
        func check(publishing: Bool = false) throws {
            lock.lock(); defer { lock.unlock() }; try checkLocked(publishing: publishing)
        }
        private func checkLocked(publishing: Bool = false) throws {
            if state == .paused { throw ReceiveStoreError.paused }
            guard state == .active || (publishing && state == .committing) else { throw failure }
            do {
                guard try clock.now() < deadline else { throw ReceiveStoreError.expired }
            } catch {
                failure = ReceiveStore.translate(error); state = .cancelled; throw failure
            }
        }
        func stop(_ mode: ReceiveStopMode) -> ReceiveStopState {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .committing: return .committing
            case .committed: return .committed
            case .cancelled: return .cancelled
            case .active, .paused:
                state = mode == .pause ? .paused : .cancelled
                return mode == .pause ? .paused : .cancelled
            }
        }
        func withPaused(_ body: () throws -> Void) throws {
            lock.lock(); defer { lock.unlock() }
            guard state == .paused else { throw ReceiveStoreError.cancelled }
            try body()
        }
        func winPublish() throws {
            lock.lock(); defer { lock.unlock() }; try checkLocked(); state = .committing
        }
        func didCommit() { lock.lock(); state = .committed; lock.unlock() }
        func didFail(_ error: ReceiveStoreError) { lock.lock(); failure = error; state = .cancelled; lock.unlock() }
    }

    private final class Directory {
        private struct Node { let fd: Int32; let name: String; let original: stat }
        private var nodes: [Node] = []
        private let url: URL
        private var securityScoped: Bool
        var label: String { nodes.last?.name ?? "接收目录" }
        var fd: Int32 { nodes.last!.fd }
        var device: dev_t { nodes.last!.original.st_dev }
        func persistentIdentity() throws -> String {
            let info = nodes.last!.original
            // st_dev belongs to a mount, not a persistent volume identity.
            let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey])
            guard let volume = values.volumeUUIDString, !volume.isEmpty else {
                throw ReceiveStoreError.unsupportedStorage
            }
            try validate()
            return "\(volume):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        }

        init(url: URL) throws {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw ReceiveStoreError.directoryChanged }
            self.url = url
            securityScoped = url.startAccessingSecurityScopedResource()
            do {
                let components = url.path.split(separator: "/").map(String.init)
                guard components.count <= 64, components.allSatisfy({ $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
                    throw ReceiveStoreError.directoryChanged
                }
                let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else { throw ReceiveStore.translate(ReceiveStoreSystemError(number: errno)) }
                try retainDescriptor(root, name: "/")
                for component in components { try openChild(component) }
                try validate()
            } catch {
                for node in nodes { Darwin.close(node.fd) }
                nodes.removeAll()
                if securityScoped { url.stopAccessingSecurityScopedResource(); securityScoped = false }
                throw error
            }
        }

        private func retainDescriptor(_ descriptor: Int32, name: String) throws {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                Darwin.close(descriptor); throw ReceiveStoreError.directoryChanged
            }
            nodes.append(Node(fd: descriptor, name: name, original: info))
        }

        private func openChild(_ name: String) throws {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                if errno == ELOOP || errno == ENOTDIR || errno == ENOENT { throw ReceiveStoreError.directoryChanged }
                throw ReceiveStore.translate(ReceiveStoreSystemError(number: errno))
            }
            try retainDescriptor(child, name: name)
        }

        func createAndOpenChild(_ name: String) throws {
            try validate()
            guard nodes.count <= 64 else { throw ReceiveStoreError.resourceLimit }
            if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw ReceiveStore.translate(ReceiveStoreSystemError(number: errno)) }
            try openChild(name)
            try validate()
        }

        func validateObject() throws {
            let last = nodes.last!
            var info = stat()
            guard fstat(last.fd, &info) == 0, Self.matches(info, last.original) else { throw ReceiveStoreError.directoryChanged }
            try Self.validatePermissions(info, descriptor: last.fd, target: true)
        }

        func validate() throws {
            for (index, node) in nodes.enumerated() {
                var opened = stat()
                guard fstat(node.fd, &opened) == 0, Self.matches(opened, node.original) else { throw ReceiveStoreError.directoryChanged }
                try Self.validatePermissions(opened, descriptor: node.fd, target: index == nodes.count - 1)
                if index > 0 {
                    var named = stat()
                    guard fstatat(nodes[index - 1].fd, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          Self.matches(named, node.original) else { throw ReceiveStoreError.directoryChanged }
                }
            }
        }

        private static func matches(_ a: stat, _ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == S_IFDIR && a.st_nlink > 0
        }
        private static func validatePermissions(_ value: stat, descriptor: Int32, target: Bool) throws {
            let own = value.st_uid == geteuid()
            guard own || (!target && value.st_uid == 0) else { throw ReceiveStoreError.unsupportedStorage }
            if value.st_mode & 0o022 != 0 {
                // Trusted sticky ancestors (e.g. /private/tmp) protect the next
                // retained root/user-owned component. The target itself must
                // not permit another principal to replace the temporary leaf.
                guard !target, value.st_mode & S_ISVTX != 0 else { throw ReceiveStoreError.unsupportedStorage }
            }
            try ReceiveStore.requireNoAllowACL(descriptor)
        }
        deinit {
            for node in nodes.reversed() { Darwin.close(node.fd) }
            if securityScoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private final class Reservation {
        private let lock = NSLock()
        private var remaining: Int64
        private var free: ((Int64) -> Void)?
        private let consumed: (Int64) -> Void
        init(size: Int64, free: @escaping (Int64) -> Void, consumed: @escaping (Int64) -> Void) {
            remaining = size; self.free = free; self.consumed = consumed
        }
        func consume(_ count: Int64) {
            lock.lock()
            guard free != nil, count >= 0, count <= remaining else { lock.unlock(); return }
            remaining -= count
            lock.unlock()
            consumed(count)
        }
        func release() {
            lock.lock(); let action = free; let rest = remaining; free = nil; remaining = 0; lock.unlock()
            action?(rest)
        }
        deinit { release() }
    }

    private final class Reservations {
        private let lock = NSLock()
        private let maximum: Int64?
        private var total: Int64 = 0
        private var volumes: [dev_t: Int64] = [:]
        init(maximum: Int64?) { self.maximum = maximum }
        func reserve(size: Int64, directory: Directory, fileSystem: ReceiveStoreFileSystem) throws -> Reservation {
            lock.lock(); defer { lock.unlock() }
            let existing = volumes[directory.device, default: 0]
            guard size <= Int64.max - total, maximum == nil || (maximum! >= total && size <= maximum! - total) else {
                throw ReceiveStoreError.resourceLimit
            }
            let available: Int64
            do { available = try fileSystem.availableBytes(directory.fd) }
            catch { throw ReceiveStore.translate(error) }
            guard existing <= available, size <= available - existing else { throw ReceiveStoreError.diskFull }
            total += size; volumes[directory.device] = existing + size
            let device = directory.device
            return Reservation(size: size, free: { [self] rest in
                lock.lock(); total -= size; volumes[device, default: 0] -= rest; lock.unlock()
            }, consumed: { [self] actual in
                lock.lock(); volumes[device, default: 0] -= actual; lock.unlock()
            })
        }
    }

    private final class Entry {
        enum Phase { case receiving, failed, cleaned, committed }
        let work = NSLock()
        let control = NSLock()
        let token: String
        let directory: Directory
        let name: String
        let size: Int64
        let expectedHash: String
        let temporaryName: String
        let originalKey: String
        let originalDeadline: Int64
        let reservation: Reservation
        private var original: stat?
        private let identity: String
        var fd: Int32 = -1
        var boundScope: Scope
        var aborted = false
        var cleanupQueued = false
        var unreturned = false
        var phase = Phase.receiving
        var offset: Int64 = 0
        var prefix = SHA256()
        var lastState = stat()
        var receipt: ReceiveReceipt?
        var scope: Scope { control.lock(); defer { control.unlock() }; return boundScope }
        var isAborted: Bool { control.lock(); defer { control.unlock() }; return aborted }
        var checkpoint: ReceiveCheckpoint {
            var hash = prefix
            return ReceiveCheckpoint(offset: offset, sha256: ReceiveStore.hex(hash.finalize()), identity: identity)
        }

        init(directory: Directory, scope: Scope, name: String, size: Int64, sha256: String, reservation: Reservation) throws {
            token = try ReceiveStore.randomToken()
            identity = try ReceiveStore.randomToken()
            temporaryName = ".chuanchuan-receive-\(token).part"
            self.directory = directory; boundScope = scope; self.name = name; self.size = size
            expectedHash = sha256; originalKey = scope.key; originalDeadline = scope.deadline
            self.reservation = reservation
        }

        func createFile(fileSystem: ReceiveStoreFileSystem) throws {
            do { fd = try fileSystem.createTemporary(directory: directory.fd, name: temporaryName) }
            catch { throw ReceiveStore.translate(error) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ReceiveStoreError.ioFailure }
            // Retain the exact identity even when the subsequent validation
            // fails, so cleanup can be retried without reopening a path.
            original = info; lastState = info
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size == 0,
                  info.st_nlink == 1, info.st_dev == directory.device, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else {
                throw ReceiveStoreError.unsupportedStorage
            }
            try ReceiveStore.requireNoAllowACL(fd)
        }

        func requireReceiving(_ token: String) throws -> Scope {
            let current = scope
            guard current.token == token else { throw ReceiveStoreError.staleScope }
            guard phase == .receiving else { throw ReceiveStoreError.cancelled }
            return current
        }

        func authorize(_ scope: Scope) throws {
            control.lock(); defer { control.unlock() }
            guard !aborted else { throw ReceiveStoreError.cancelled }
            try scope.check()
        }

        func requestAbort() {
            control.lock(); aborted = true; let current = boundScope; control.unlock()
            _ = current.stop(.cancel)
        }

        func winPublish(_ permit: Scope) throws {
            control.lock(); defer { control.unlock() }
            guard !aborted else { throw ReceiveStoreError.cancelled }
            try permit.winPublish()
        }

        func sameIdentity(_ value: stat) -> Bool {
            guard let original else { return false }
            return value.st_dev == original.st_dev && value.st_ino == original.st_ino && value.st_mode & S_IFMT == S_IFREG &&
            value.st_birthtimespec.tv_sec == original.st_birthtimespec.tv_sec && value.st_birthtimespec.tv_nsec == original.st_birthtimespec.tv_nsec
        }

        func captureOriginalIfMissing(_ value: stat) {
            // If initial fstat itself failed, the still-open exclusive create
            // descriptor remains the authority; no path was reopened meanwhile.
            if original == nil { original = value }
        }

        @discardableResult
        func validateFile(expectedSize: Int64, unchanged: stat? = nil) throws -> stat {
            var opened = stat()
            var named = stat()
            guard fd >= 0, fstat(fd, &opened) == 0, sameIdentity(opened), opened.st_nlink == 1,
                  opened.st_size == expectedSize, opened.st_uid == geteuid(), opened.st_mode & 0o777 == 0o600,
                  fstatat(directory.fd, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  sameIdentity(named), named.st_nlink == 1, named.st_size == expectedSize else { throw ReceiveStoreError.sourceChanged }
            try ReceiveStore.requireNoAllowACL(fd)
            if let unchanged {
                guard opened.st_mtimespec.tv_sec == unchanged.st_mtimespec.tv_sec,
                      opened.st_mtimespec.tv_nsec == unchanged.st_mtimespec.tv_nsec,
                      opened.st_ctimespec.tv_sec == unchanged.st_ctimespec.tv_sec,
                      opened.st_ctimespec.tv_nsec == unchanged.st_ctimespec.tv_nsec else { throw ReceiveStoreError.sourceChanged }
            }
            return opened
        }

        func closeDescriptor() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
        deinit { closeDescriptor() }
    }
}

/// Internal syscall boundary for deterministic fault/race tests. Production
/// always calls the fd-relative Darwin functions below, with no path fallback.
internal struct ReceiveStoreSystemError: Error { let number: Int32 }

internal class ReceiveStoreFileSystem {
    // Internal deterministic lifecycle seams; production does no work here.
    // The lock never escapes through a public store or channel API.
    func didRegisterTemporary(work: NSLock) {}
    func didFinishCleanup() {}
    func createTemporary(directory: Int32, name: String) throws -> Int32 {
        let fd = openat(directory, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ReceiveStoreSystemError(number: errno) }
        return fd
    }
    func write(_ fd: Int32, bytes: UnsafeRawPointer, count: Int, offset: Int64) throws -> Int {
        let result = Darwin.pwrite(fd, bytes, count, off_t(offset))
        guard result >= 0 else { throw ReceiveStoreSystemError(number: errno) }
        return result
    }
    func read(_ fd: Int32, bytes: UnsafeMutableRawPointer, count: Int, offset: Int64) throws -> Int {
        let result = Darwin.pread(fd, bytes, count, off_t(offset))
        guard result >= 0 else { throw ReceiveStoreSystemError(number: errno) }
        return result
    }
    func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw ReceiveStoreSystemError(number: errno) }
    }
    func rename(directory: Int32, from: String, to: String) throws {
        guard renameatx_np(directory, from, directory, to, UInt32(RENAME_EXCL)) == 0 else {
            throw ReceiveStoreSystemError(number: errno)
        }
    }
    func unlink(directory: Int32, name: String) throws {
        guard unlinkat(directory, name, 0) == 0 else { throw ReceiveStoreSystemError(number: errno) }
    }
    func availableBytes(_ fd: Int32) throws -> Int64 {
        var info = statfs()
        guard fstatfs(fd, &info) == 0 else { throw ReceiveStoreSystemError(number: errno) }
        let value = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        return value.overflow || value.partialValue > UInt64(Int64.max) ? Int64.max : Int64(value.partialValue)
    }
    func requireSupportedVolume(_ fd: Int32) throws {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { throw ReceiveStore.translate(ReceiveStoreSystemError(number: errno)) }
        guard fs.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ReceiveStoreError.unsupportedStorage }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // getattrlist packs all attributes on four-byte boundaries. Length +
        // eight UInt32 fields avoids relying on a Swift aggregate C layout.
        var words = [UInt32](repeating: 0, count: 9)
        let result = words.withUnsafeMutableBytes {
            fgetattrlist(fd, &attributes, $0.baseAddress!, $0.count, 0)
        }
        let bit = UInt32(VOL_CAP_INT_RENAME_EXCL)
        guard result == 0, words[0] == 36, words[2] & bit != 0, words[6] & bit != 0 else {
            throw ReceiveStoreError.unsupportedStorage
        }
    }
}
