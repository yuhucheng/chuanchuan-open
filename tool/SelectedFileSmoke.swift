// Real local-file checks; compile with SelectedFileStore.swift using swiftc.
import Foundation
import CryptoKit
import Darwin

@main
struct SelectedFileSmoke {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("sharehub-files-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let store = SelectedFileStore()
        defer { store.shutdown() }
        let url = directory.appendingPathComponent("generated.bin")
        let total = 10 * 1024 * 1024 + 17
        fm.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        var expected = SHA256()
        var offset = 0
        while offset < total {
            let count = min(64 * 1024, total - offset)
            let chunk = Data((0..<count).map { UInt8((offset + $0) % 251) })
            try writer.write(contentsOf: chunk)
            expected.update(data: chunk)
            offset += count
        }
        try writer.close()
        let info = try store.add([url])[0]
        precondition(info.size == total && info.name == "generated.bin")
        try expectFailure { try store.finish(token: info.token) }
        try expectFailure { _ = try store.read(token: info.token, offset: 1, length: 1) }
        try expectFailure { _ = try store.read(token: info.token, offset: 0, length: SelectedFileStore.maximumChunk + 1) }
        var digest = SHA256()
        var readBytes: Int64 = 0
        var maximumChunk = 0
        while readBytes < info.size {
            let data = try store.read(token: info.token, offset: readBytes, length: SelectedFileStore.maximumChunk)
            digest.update(data: data)
            readBytes += Int64(data.count)
            maximumChunk = max(maximumChunk, data.count)
        }
        try store.finish(token: info.token)
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        precondition(hash == expected.finalize().map { String(format: "%02x", $0) }.joined())
        store.release(token: info.token)
        store.release(token: info.token)
        try expectFailure { _ = try store.read(token: info.token, offset: 0, length: 1) }
        precondition(store.count == 0)

        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)
        let emptyInfo = try store.add([empty])[0]
        try store.finish(token: emptyInfo.token)
        store.release(token: emptyInfo.token)

        // In-place size changes and path replacement must invalidate a token.
        let changing = directory.appendingPathComponent("changing")
        try Data([1, 2, 3]).write(to: changing)
        let changed = try store.add([changing])[0]
        let modifier = try FileHandle(forWritingTo: changing)
        try modifier.truncate(atOffset: 2)
        try modifier.close()
        try expectFailure { _ = try store.read(token: changed.token, offset: 0, length: 3) }
        store.release(token: changed.token)
        try Data([1, 2, 3]).write(to: changing)
        let replaced = try store.add([changing])[0]
        try fm.removeItem(at: changing)
        try Data([1, 2, 3]).write(to: changing)
        try expectFailure { _ = try store.read(token: replaced.token, offset: 0, length: 3) }
        store.release(token: replaced.token)

        // A bad batch cannot leak the earlier valid selection.
        try expectFailure { _ = try store.add([empty, directory]) }
        precondition(store.count == 0)
        let symlink = directory.appendingPathComponent("link")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: empty)
        try expectFailure { _ = try store.add([symlink]) }
        let fifo = directory.appendingPathComponent("pipe")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        try expectFailure { _ = try store.add([fifo]) }
        precondition(store.count == 0)
        try expectFailure { _ = try store.add(Array(repeating: empty, count: 65)) }
        let last = try store.add([empty])[0]
        store.shutdown()
        store.shutdown()
        try expectFailure { _ = try store.add([empty]) }
        try expectFailure { _ = try store.read(token: last.token, offset: 0, length: 1) }
        precondition(store.count == 0)

        let result: [String: Any] = [
            "scope": "real generated local files; no NSOpenPanel, sandbox permission prompt, or network",
            "bytes": total, "sha256": hash, "maximumChunkBytes": maximumChunk,
            "checks": ["incremental_content", "empty_file", "incomplete_finish", "wrong_offset", "chunk_limit", "closed_token", "in_place_change", "path_replacement", "batch_rollback", "directory_rejection", "symlink_rejection", "nonblocking_fifo_rejection", "file_count_limit", "shutdown"],
            "result": "passed"
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }

    private static func expectFailure(_ action: () throws -> Void) throws {
        do { try action(); fatalError("Expected SelectedFileError") }
        catch is SelectedFileError {}
    }
}
