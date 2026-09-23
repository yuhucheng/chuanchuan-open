import Cocoa
import CoreFoundation
import FlutterMacOS

/// Source capabilities share one bounded executor for local and authorized
/// work. Only main owns Flutter callbacks and creates typed channel results.
final class SourceAccessBridge {
    private let store = SelectedFileStore()
    private let dispatcher = ReceiveWorkDispatcher()
    private var closed = false

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        precondition(Thread.isMainThread)
        let authorized = call.method.hasPrefix("files.source.")
        guard !closed else { result(Self.failure(SourceFileError.closed, authorized: authorized)); return }
        do {
            switch call.method {
            case "files.source.scopeOpen":
                let args = try Self.arguments(call.arguments)
                result(try store.scopeOpen(token: Self.text(args["token"]), key: Self.text(args["key"]),
                    deadlineMicros: Self.integer(args["deadlineMicros"])))
            case "files.source.scopeStop":
                let args = try Self.arguments(call.arguments)
                guard let mode = SourceStopMode(rawValue: try Self.text(args["mode"])) else { throw SourceFileError.invalidScope }
                result(try store.scopeStop(scope: Self.text(args["scope"]), mode: mode).rawValue)
            case "files.source.scopeClose":
                store.scopeClose(scope: try Self.text(call.arguments)); result(nil)
            case "files.release":
                // Release is also an immediate native gate, never a queued fd
                // close racing a previously admitted read.
                store.release(token: try Self.text(call.arguments)); result(nil)
            case "files.source.beginPass":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), scope = try Self.text(args["scope"])
                let store = self.store
                perform(result, keys: ["e:" + token, "s:" + scope], authorized: true, deliver: { value in
                    guard let pass = value as? String else { throw SourceFileError.sourceUnavailable }
                    try store.validateSourceDelivery(token: token, scope: scope, passId: pass)
                    return pass
                }) { try $0.beginPass(token: token, scope: scope) }
            case "files.source.readPass", "files.source.finishPass":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), scope = try Self.text(args["scope"])
                let pass = try Self.text(args["passId"])
                let store = self.store
                let deliver: (Any?) throws -> Any? = { value in
                    try store.validateSourceDelivery(token: token, scope: scope, passId: pass)
                    return Self.channelValue(value)
                }
                if call.method == "files.source.readPass" {
                    let offset = try Self.integer(args["offset"]), length = try Self.length(args["length"])
                    guard offset >= 0 else { throw SourceFileError.invalidRead }
                    perform(result, keys: ["e:" + token, "s:" + scope], authorized: true, deliver: deliver) {
                        try $0.readPass(token: token, scope: scope, passId: pass, offset: offset, length: length)
                    }
                } else {
                    perform(result, keys: ["e:" + token, "s:" + scope], authorized: true, deliver: deliver) {
                        try $0.finishPass(token: token, scope: scope, passId: pass); return nil
                    }
                }
            case "files.beginReadPass":
                let token = try Self.text(call.arguments)
                let store = self.store
                perform(result, keys: ["e:" + token], deliver: { value in
                    guard let pass = value as? String else { throw SelectedFileError.unavailable }
                    try store.validateLegacyDelivery(token: token, passId: pass)
                    return pass
                }) { try $0.beginReadPass(token: token) }
            case "files.read", "files.readPass":
                let args = try Self.arguments(call.arguments)
                let token = try Self.text(args["token"]), offset = try Self.integer(args["offset"])
                let length = try Self.length(args["length"])
                let pass: String?
                if call.method == "files.readPass" { pass = try Self.text(args["passId"]) } else { pass = nil }
                guard offset >= 0 else { throw SelectedFileError.invalidRead }
                let store = self.store
                perform(result, keys: ["e:" + token], deliver: { value in
                    try store.validateLegacyDelivery(token: token, passId: pass)
                    return Self.channelValue(value)
                }) {
                    if let pass { return try $0.readPass(token: token, passId: pass, offset: offset, length: length) }
                    return try $0.read(token: token, offset: offset, length: length)
                }
            case "files.finish", "files.finishPass":
                let token: String, pass: String?
                if call.method == "files.finishPass" {
                    let args = try Self.arguments(call.arguments)
                    token = try Self.text(args["token"]); pass = try Self.text(args["passId"])
                } else { token = try Self.text(call.arguments); pass = nil }
                let store = self.store
                perform(result, keys: ["e:" + token], deliver: { value in
                    try store.validateLegacyDelivery(token: token, passId: pass)
                    return value
                }) {
                    if let pass { try $0.finishPass(token: token, passId: pass) }
                    else { try $0.finish(token: token) }
                    return nil
                }
            default: result(FlutterMethodNotImplemented)
            }
        } catch { result(Self.failure(error, authorized: authorized)) }
    }

    func acceptPickedFiles(_ urls: [URL], result: @escaping FlutterResult) {
        acceptNativeFiles(urls) { outcome in
            switch outcome {
            case .success(let selected): result(selected.map(\.dictionary))
            case .failure(let error): result(Self.failure(error, authorized: false))
            }
        }
    }

    /// Only picker/drop callers can supply these URLs; there is no path method.
    func acceptNativeFiles(_ urls: [URL], completion: @escaping (Result<[SelectedFileInfo], Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !closed else { completion(.failure(SourceFileError.closed)); return }
        guard urls.count <= SelectedFileStore.maximumFiles else { completion(.failure(SelectedFileError.limit)); return }
        let store = self.store
        do {
            try dispatcher.submit(keys: ["selection"], work: { try store.add(urls) }) { outcome in
                do {
                    guard let selected = try outcome.get() as? [SelectedFileInfo] else { throw SelectedFileError.unavailable }
                    do { for entry in selected { try store.validateLegacyDelivery(token: entry.token) } }
                    catch {
                        for entry in selected { store.release(token: entry.token) }
                        throw error
                    }
                    completion(.success(selected))
                } catch { completion(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }

    func discardNativeFiles(_ files: [SelectedFileInfo]) {
        precondition(Thread.isMainThread)
        for file in files { store.release(token: file.token) }
    }

    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true
        store.shutdown()
        dispatcher.close()
    }
    deinit { store.shutdown() }

    private func perform(_ result: @escaping FlutterResult, keys: [String], authorized: Bool = false,
                         deliver: @escaping (Any?) throws -> Any? = { $0 },
                         work: @escaping (SelectedFileStore) throws -> Any?) {
        let store = self.store
        do {
            try dispatcher.submit(keys: keys, work: { try work(store) }) { outcome in
                do { result(try deliver(outcome.get())) }
                catch { result(Self.failure(error, authorized: authorized)) }
            }
        } catch { result(Self.failure(error, authorized: authorized)) }
    }
    private static func channelValue(_ value: Any?) -> Any? {
        precondition(Thread.isMainThread)
        if let data = value as? Data { return FlutterStandardTypedData(bytes: data) }
        return value
    }
    private static func failure(_ error: Error, authorized: Bool) -> FlutterError {
        if !authorized {
            let local: SelectedFileError
            if let value = error as? SelectedFileError { local = value }
            else if let value = error as? ReceiveDispatchError { local = value == .closed ? .closed : .limit }
            else if let value = error as? SourceFileError { local = value == .closed || value == .invalidToken || value == .stopped ? .closed : .invalidRead }
            else { local = .unavailable }
            return FlutterError(code: "file_access", message: local.message, details: nil)
        }
        let code: String
        if let error = error as? SourceFileError { code = error.rawValue }
        else if let error = error as? ReceiveDispatchError { code = error == .closed ? "closed" : "resource_limit" }
        else { code = "source_unavailable" }
        return FlutterError(code: code, message: "源文件访问失败。", details: nil)
    }
    private static func arguments(_ value: Any?) throws -> [String: Any] {
        guard let map = value as? [String: Any], map.count <= 6 else { throw SourceFileError.invalidRead }
        return map
    }
    private static func text(_ value: Any?) throws -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 256, !text.utf8.contains(0) else { throw SourceFileError.invalidToken }
        return text
    }
    private static func integer(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q"].contains(String(cString: number.objCType)) else { throw SourceFileError.invalidRead }
        return number.int64Value
    }
    private static func length(_ value: Any?) throws -> Int {
        let count = try integer(value)
        guard count > 0, count <= Int64(SelectedFileStore.maximumChunk) else { throw SourceFileError.invalidRead }
        return Int(count)
    }
}
