import Foundation
import Darwin

public enum SelectedFileError: Error {
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

public struct SelectedFileInfo {
    public let token: String
    public let name: String
    public let size: Int64
    public var dictionary: [String: Any] { ["token": token, "name": name, "size": size] }
}

/// Owns access only to URLs supplied by the native file picker. All methods
/// must run on one serial queue. No path from Flutter or a peer is accepted.
public final class SelectedFileStore {
    public static let maximumFiles = 64
    public static let maximumChunk = 256 * 1024
    private var entries: [String: Entry] = [:]
    private var closed = false
    public var count: Int { entries.count }

    public init() {}

    /// A selection is atomic: any invalid file releases the whole new batch.
    public func add(_ urls: [URL]) throws -> [SelectedFileInfo] {
        guard !closed else { throw SelectedFileError.closed }
        guard urls.count <= Self.maximumFiles - entries.count else { throw SelectedFileError.limit }
        var pending: [Entry] = []
        do {
            for url in urls { pending.append(try Entry(url: url)) }
        } catch {
            for entry in pending { entry.close() }
            throw error
        }
        for entry in pending { entries[entry.info.token] = entry }
        return pending.map(\.info)
    }

    public func read(token: String, offset: Int64, length: Int) throws -> Data {
        guard let entry = entries[token], !closed else { throw SelectedFileError.closed }
        guard length > 0, length <= Self.maximumChunk,
              offset >= 0, offset == entry.offset, offset <= entry.info.size else {
            throw SelectedFileError.invalidRead
        }
        try entry.validate()
        let count = min(length, Int(entry.info.size - offset))
        let data: Data
        do { data = try entry.handle.read(upToCount: count) ?? Data() }
        catch { throw SelectedFileError.unavailable }
        guard data.count == count else { throw SelectedFileError.changed }
        try entry.validate()
        entry.offset += Int64(data.count)
        return data
    }

    public func finish(token: String) throws {
        guard let entry = entries[token], !closed else { throw SelectedFileError.closed }
        try entry.validate()
        guard entry.offset == entry.info.size else { throw SelectedFileError.incomplete }
    }

    public func release(token: String) {
        entries.removeValue(forKey: token)?.close()
    }

    public func shutdown() {
        closed = true
        for entry in entries.values { entry.close() }
        entries.removeAll()
    }

    deinit { for entry in entries.values { entry.close() } }

    private final class Entry {
        let info: SelectedFileInfo
        let url: URL
        let handle: FileHandle
        let original: stat
        var offset: Int64 = 0
        private var scope: Bool
        private var isClosed = false

        init(url: URL) throws {
            guard url.isFileURL else { throw SelectedFileError.unavailable }
            let scope = url.startAccessingSecurityScopedResource()
            // NONBLOCK avoids hanging on a selected FIFO; fstat below admits
            // regular files only. NOFOLLOW rejects replaced symbolic links.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                if scope { url.stopAccessingSecurityScopedResource() }
                throw SelectedFileError.unavailable
            }
            var snapshot = stat()
            guard fstat(descriptor, &snapshot) == 0,
                  snapshot.st_mode & S_IFMT == S_IFREG, snapshot.st_size >= 0 else {
                Darwin.close(descriptor)
                if scope { url.stopAccessingSecurityScopedResource() }
                throw SelectedFileError.unavailable
            }
            self.url = url
            self.scope = scope
            original = snapshot
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            info = SelectedFileInfo(token: UUID().uuidString.lowercased(), name: url.lastPathComponent, size: snapshot.st_size)
        }

        func validate() throws {
            var descriptorState = stat()
            var pathState = stat()
            guard !isClosed, fstat(handle.fileDescriptor, &descriptorState) == 0,
                  lstat(url.path, &pathState) == 0,
                  matches(descriptorState), matches(pathState) else { throw SelectedFileError.changed }
        }

        private func matches(_ value: stat) -> Bool {
            value.st_dev == original.st_dev && value.st_ino == original.st_ino &&
            value.st_size == original.st_size && value.st_mode & S_IFMT == S_IFREG &&
            value.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec &&
            value.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec &&
            value.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec &&
            value.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            // FileHandle also owns the fd; close is idempotent at this layer.
            try? handle.close()
            if scope { url.stopAccessingSecurityScopedResource(); scope = false }
        }
    }
}
