import Cocoa
import FlutterMacOS

final class FileAccessBridge {
    private let queue = DispatchQueue(label: "dev.sharehub.client.selected-files", qos: .userInitiated)
    private let store = SelectedFileStore()
    private var panel: NSOpenPanel?
    private var closed = false
    // Main-thread delivery. Only the acknowledgement transfers ownership to Dart.
    var sendDrop: (([[String: Any]], @escaping (Bool) -> Void) -> Void)?
    var sendDropError: ((String) -> Void)?
    var canAcceptDrop: Bool { !closed && panel == nil && sendDrop != nil }

    @discardableResult
    func acceptDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard canAcceptDrop else { return false }
        let urls: [URL]
        do { urls = try NativeFileDrop.urls(from: pasteboard) }
        catch { sendDropError?(self.error(error).message ?? "文件拖入失败。"); return false }
        queue.async {
            do {
                let files = try self.store.add(urls)
                DispatchQueue.main.async {
                    guard !self.closed, let send = self.sendDrop else {
                        self.releaseDrop(files); return
                    }
                    var settled = false
                    let settle: (Bool) -> Void = { accepted in
                        guard !settled else { return }
                        settled = true
                        if !accepted || self.closed { self.releaseDrop(files) }
                    }
                    // Missing handlers, failed delivery and a silent engine
                    // must not retain capabilities indefinitely.
                    let timeout = DispatchWorkItem { settle(false) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
                    send(files.map(\.dictionary)) { accepted in
                        DispatchQueue.main.async { timeout.cancel(); settle(accepted) }
                    }
                }
            } catch {
                let message = self.error(error).message ?? "文件拖入失败。"
                DispatchQueue.main.async {
                    if !self.closed { self.sendDropError?(message) }
                }
            }
        }
        return true
    }

    private func releaseDrop(_ files: [SelectedFileInfo]) {
        queue.async { for file in files { self.store.release(token: file.token) } }
    }

    func handle(_ call: FlutterMethodCall, window: NSWindow, result: @escaping FlutterResult) {
        guard !closed else { result(error(SelectedFileError.closed)); return }
        switch call.method {
        case "files.pick":
            guard panel == nil else { result(error(SelectedFileError.unavailable)); return }
            let picker = NSOpenPanel()
            panel = picker
            picker.title = "选择要传送的文件"
            picker.prompt = "加入队列"
            picker.message = "只读取你选择的文件。当前版本先准备文件，连接功能尚未开放。"
            picker.canChooseDirectories = false
            picker.canChooseFiles = true
            picker.allowsMultipleSelection = true
            picker.resolvesAliases = false
            picker.beginSheetModal(for: window) { [self] response in
                panel = nil
                guard !closed, response == .OK else { result([]); return }
                let urls = picker.urls
                perform(result) { try self.store.add(urls).map(\.dictionary) }
            }
        case "files.read":
            guard let args = call.arguments as? [String: Any], let token = args["token"] as? String,
                  let offset = args["offset"] as? Int64, let length = args["length"] as? Int else {
                result(error(SelectedFileError.invalidRead)); return
            }
            perform(result) { FlutterStandardTypedData(bytes: try self.store.read(token: token, offset: offset, length: length)) }
        case "files.finish":
            guard let token = call.arguments as? String else { result(error(SelectedFileError.closed)); return }
            perform(result) { try self.store.finish(token: token); return nil }
        case "files.release":
            guard let token = call.arguments as? String else { result(error(SelectedFileError.closed)); return }
            perform(result) { self.store.release(token: token); return nil }
        default: result(FlutterMethodNotImplemented)
        }
    }

    func cancelPicker() { panel?.cancel(nil) }

    func close() {
        closed = true
        sendDrop = nil
        sendDropError = nil
        panel?.cancel(nil)
        panel = nil
        queue.async { self.store.shutdown() }
    }

    private func perform(_ result: @escaping FlutterResult, work: @escaping () throws -> Any?) {
        queue.async {
            do {
                let value = try work()
                DispatchQueue.main.async { result(value) }
            } catch {
                let failure = self.error(error)
                DispatchQueue.main.async { result(failure) }
            }
        }
    }

    private func error(_ error: Error) -> FlutterError {
        FlutterError(code: "file_access", message: (error as? SelectedFileError)?.message ?? "文件操作失败，请重新选择。", details: nil)
    }
}
