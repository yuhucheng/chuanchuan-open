import Cocoa
import FlutterMacOS

final class FileAccessBridge {
    private let queue = DispatchQueue(label: "dev.sharehub.client.selected-files", qos: .userInitiated)
    private let store = SelectedFileStore()
    private var panel: NSOpenPanel?
    private var closed = false

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
