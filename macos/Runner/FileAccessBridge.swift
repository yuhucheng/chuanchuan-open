import Cocoa
import FlutterMacOS

final class FileAccessBridge {
    private let source = SourceAccessBridge()
    private let receive = ReceiveAccessBridge()
    private var panel: NSOpenPanel?
    private var closed = false
    private var drops: FileDropBridge?

    func configureFileDrop(messenger: FlutterBinaryMessenger) {
        precondition(Thread.isMainThread)
        guard !closed, drops == nil else { return }
        drops = FileDropBridge(messenger: messenger, source: source)
    }
    func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !closed, panel == nil else { return [] }
        return drops?.operation(sender) ?? []
    }
    func acceptDrop(_ sender: NSDraggingInfo, view: NSView) -> Bool {
        guard !closed, panel == nil else { return false }
        return drops?.accept(sender, view: view) ?? false
    }

    func handle(_ call: FlutterMethodCall, window: NSWindow, result: @escaping FlutterResult) {
        precondition(Thread.isMainThread)
        if call.method.hasPrefix("files.receive.") {
            guard !closed else { result(ReceiveAccessBridge.closedError); return }
            if call.method == "files.receive.directoryPick" {
                pickReceiveDirectory(call, window: window, result: result)
            } else { receive.handle(call, result: result) }
            return
        }
        if call.method.hasPrefix("files.source.") { source.handle(call, result: result); return }
        guard !closed else { result(error(SelectedFileError.closed)); return }
        switch call.method {
        case "files.pick":
            guard panel == nil else { result(error(SelectedFileError.unavailable)); return }
            let picker = NSOpenPanel()
            panel = picker
            picker.title = "选择要传送的文件"
            picker.prompt = "加入队列"
            picker.message = "只读取你选择的普通文件，准备完成后可发送到已连接设备。"
            picker.canChooseDirectories = false
            picker.canChooseFiles = true
            picker.allowsMultipleSelection = true
            picker.resolvesAliases = false
            picker.beginSheetModal(for: window) { [self] response in
                panel = nil
                guard !closed else { return }
                guard response == .OK else { result([]); return }
                let urls = picker.urls
                source.acceptPickedFiles(urls, result: result)
            }
        default: source.handle(call, result: result)
        }
    }

    func cancelPicker() { precondition(Thread.isMainThread); drops?.cancel(); panel?.cancel(nil) }

    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true
        drops?.close()
        receive.close()
        source.close()
        panel?.cancel(nil)
        panel = nil
    }

    private func pickReceiveDirectory(_ call: FlutterMethodCall, window: NSWindow, result: @escaping FlutterResult) {
        guard call.arguments == nil || call.arguments is NSNull else {
            result(ReceiveAccessBridge.failure(ReceiveStoreError.invalidRange)); return
        }
        // Source-file and receive-directory selection share one native panel.
        guard panel == nil else { result(ReceiveAccessBridge.failure(ReceiveStoreError.resourceLimit)); return }
        let picker = NSOpenPanel()
        panel = picker
        picker.title = "选择接收文件夹"
        picker.prompt = "选择"
        picker.message = "收到的文件将保存到所选文件夹，同名文件会保留两者。"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.resolvesAliases = false
        picker.beginSheetModal(for: window) { [self] response in
            panel = nil
            guard !closed else { return }
            guard response == .OK, let url = picker.url else { result(nil); return }
            receive.acceptPickedDirectory(url, result: result)
        }
    }

    private func error(_ error: Error) -> FlutterError {
        FlutterError(code: "file_access", message: (error as? SelectedFileError)?.message ?? "文件操作失败，请重新选择。", details: nil)
    }
}
