import Cocoa
import CoreFoundation
import FlutterMacOS

/// Main-thread channel endpoint. No remote/Dart path is accepted; only the
/// existing native panel calls acceptPickedDirectory with a selected URL.
final class ReceiveAccessBridge {
    private let store = ReceiveStore(preferences: ReceiveDirectoryPreferences())
    private let dispatcher = ReceiveWorkDispatcher()
    private var closed = false

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        precondition(Thread.isMainThread)
        guard !closed else { result(Self.closedError); return }
        do {
            switch call.method {
            // Control methods bypass the disk executor, including when all
            // 64 work/completion slots are occupied by slow filesystem work.
            case "files.receive.scopeOpen":
                let args = try Self.arguments(call.arguments)
                result(try store.scopeOpen(key: Self.text(args["key"]), deadlineMicros: Self.integer(args["deadlineMicros"])))
            case "files.receive.scopeStop":
                let args = try Self.arguments(call.arguments)
                guard let mode = ReceiveStopMode(rawValue: try Self.text(args["mode"])) else { throw ReceiveStoreError.invalidRange }
                result(try store.scopeStop(scope: Self.text(args["scope"]), mode: mode).rawValue)
            case "files.receive.scopeClose":
                store.scopeClose(scope: try Self.text(call.arguments)); result(nil)
            case "files.receive.abort":
                store.abort(token: try Self.text(call.arguments)); result(nil)
            case "files.receive.directoryConfigured":
                guard call.arguments == nil || call.arguments is NSNull else { throw ReceiveStoreError.invalidRange }
                perform(result, keys: ["directory-settings"]) { try $0.directoryConfigured().dictionary }
            case "files.receive.directoryRelease":
                let token = try Self.text(call.arguments)
                perform(result, keys: ["d:" + token]) { $0.directoryRelease(token: token); return nil }
            case "files.receive.begin":
                let args = try Self.arguments(call.arguments)
                let directory = try Self.text(args["directory"]), scope = try Self.text(args["scope"])
                let name = try Self.text(args["name"]), hash = try Self.text(args["sha256"], maximum: 64)
                let size = try Self.integer(args["size"])
                guard size >= 0 else { throw ReceiveStoreError.invalidRange }
                perform(result, keys: ["d:" + directory, "s:" + scope]) {
                    try $0.begin(directory: directory, scope: scope, name: name, size: size, sha256: hash)
                }
            case "files.receive.append":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), scope = try Self.text(args["scope"])
                let offset = try Self.integer(args["offset"])
                guard offset >= 0, let typed = args["bytes"] as? FlutterStandardTypedData,
                      typed.elementSize == 1, !typed.data.isEmpty, typed.data.count <= ReceiveStore.maximumChunk else {
                    throw ReceiveStoreError.invalidRange
                }
                let bytes = typed.data
                perform(result, keys: ["e:" + token, "s:" + scope]) { try $0.append(token: token, scope: scope, offset: offset, bytes: bytes) }
            case "files.receive.checkpoint":
                let token = try Self.text(call.arguments)
                perform(result, keys: ["e:" + token]) { try $0.checkpoint(token: token).dictionary }
            case "files.receive.resume":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), scope = try Self.text(args["scope"])
                let checkpoint = ReceiveCheckpoint(offset: try Self.integer(args["offset"]),
                    sha256: try Self.text(args["sha256"], maximum: 64), identity: try Self.text(args["identity"]))
                guard checkpoint.offset >= 0 else { throw ReceiveStoreError.invalidRange }
                perform(result, keys: ["e:" + token, "s:" + scope]) { try $0.resume(token: token, scope: scope, checkpoint: checkpoint); return nil }
            case "files.receive.commit":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), scope = try Self.text(args["scope"])
                perform(result, keys: ["e:" + token, "s:" + scope]) { try $0.commit(token: token, scope: scope).dictionary }
            case "files.receive.retryCleanup":
                let token = try Self.text(call.arguments)
                perform(result, keys: ["e:" + token]) { try $0.retryCleanup(token: token); return nil }
            case "files.receive.release":
                let token = try Self.text(call.arguments)
                perform(result, keys: ["e:" + token]) { try $0.release(token: token); return nil }
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(Self.failure(error)) }
    }

    func acceptPickedDirectory(_ url: URL, result: @escaping FlutterResult) {
        precondition(Thread.isMainThread)
        guard !closed else { result(Self.closedError); return }
        perform(result, keys: ["directory-settings"]) { try $0.directoryFromPicker(url).dictionary }
    }

    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true
        store.shutdown() // Synchronous stop barrier; cleanup is asynchronous.
        dispatcher.close()
    }

    deinit { store.shutdown() }

    private func perform(_ result: @escaping FlutterResult, keys: [String] = [], work: @escaping (ReceiveStore) throws -> Any?) {
        let store = self.store
        do {
            try dispatcher.submit(keys: keys, work: {
                // Bounded, original-object retry sweep; never a directory scan.
                try? store.retryPendingCleanup()
                return try work(store)
            }) { outcome in
                switch outcome {
                case .success(let value): result(value)
                case .failure(let error): result(Self.failure(error))
                }
            }
        } catch { result(Self.failure(error)) }
    }

    static var closedError: FlutterError { FlutterError(code: "closed", message: "客户端已关闭。", details: nil) }
    static func failure(_ error: Error) -> FlutterError {
        let code: String
        if let error = error as? ReceiveStoreError { code = error.rawValue }
        else if let error = error as? ReceiveDispatchError {
            code = error == .closed ? "closed" : "resource_limit"
        } else { code = "io_failure" }
        return FlutterError(code: code, message: "接收文件操作失败。", details: nil)
    }

    private static func arguments(_ value: Any?) throws -> [String: Any] {
        guard let map = value as? [String: Any], map.count <= 8 else { throw ReceiveStoreError.invalidRange }
        return map
    }
    private static func text(_ value: Any?, maximum: Int = 256) throws -> String {
        guard let value = value as? String, !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= maximum else {
            throw ReceiveStoreError.invalidToken
        }
        return value
    }
    private static func integer(_ value: Any?) throws -> Int64 {
        // NSNumber also bridges Bool and floating point; reject both rather
        // than accepting true as offset 1 or silently truncating a Double.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { throw ReceiveStoreError.invalidRange }
        let kind = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q"].contains(kind) else { throw ReceiveStoreError.invalidRange }
        return number.int64Value
    }
}
