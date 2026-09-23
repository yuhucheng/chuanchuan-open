import Cocoa
import FlutterMacOS

/// AppKit keeps path authority. Flutter gets a logical point and native tokens.
final class FileDropBridge {
    private let channel: FlutterMethodChannel
    private let session: FileDropSession
    private var closed = false

    init(messenger: FlutterBinaryMessenger, source: SourceAccessBridge) {
        let channel = FlutterMethodChannel(name: "dev.sharehub.client/file-drop", binaryMessenger: messenger)
        self.channel = channel
        session = FileDropSession(
            locate: { x, y, reply in
                channel.invokeMethod("locate", arguments: ["x": x, "y": y]) { reply($0 as? Bool == true) }
            },
            prepare: { urls, completion in source.acceptNativeFiles(urls, completion: completion) },
            release: { files in source.discardNativeFiles(files) },
            offer: { files, x, y, reply in
                channel.invokeMethod("drop", arguments: ["x": x, "y": y, "files": files.map(\.dictionary)]) {
                    reply($0 as? Bool == true)
                }
            },
            onError: { channel.invokeMethod("error", arguments: nil) })
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self, !self.closed else {
                result(FlutterError(code: "closed", message: "客户端已关闭。", details: nil)); return
            }
            guard call.arguments == nil || call.arguments is NSNull else {
                result(FlutterError(code: "invalid_arguments", message: "拖放监听不接收文件路径。", details: nil)); return
            }
            switch call.method {
            case "listen": self.session.listen(); result(nil)
            case "cancel": self.session.cancel(); result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
        precondition(Thread.isMainThread)
        guard !closed, session.ready, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else { return [] }
        return .copy
    }

    func accept(_ sender: NSDraggingInfo, view: NSView) -> Bool {
        precondition(Thread.isMainThread)
        guard operation(sender) == .copy else { return false }
        let board = sender.draggingPasteboard
        let revision = board.changeCount
        guard let items = board.pasteboardItems, !items.isEmpty,
              items.count <= SelectedFileStore.maximumFiles else { return false }
        // Bound our copy before NSURL decoding, and reject mixed/promise batches.
        guard items.allSatisfy({ item in
            guard let data = item.data(forType: .fileURL) else { return false }
            return !data.isEmpty && data.count <= 64 * 1024
        }) else { return false }
        // AppKit resolves the OS pasteboard object, retaining its sandbox grant;
        // parsing a Flutter/path string here would not be equivalent authority.
        guard let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == items.count, board.changeCount == revision,
              urls.allSatisfy({ $0.isFileURL && $0.absoluteString.utf8.count <= 64 * 1024 }) else { return false }
        let point = view.convert(sender.draggingLocation, from: nil)
        let x = point.x - view.bounds.minX
        let y = view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y
        return session.accept(urls, x: Double(x), y: Double(y))
    }

    func cancel() { session.cancel() }
    func close() {
        guard !closed else { return }
        closed = true
        session.close()
        channel.setMethodCallHandler(nil)
    }
    deinit { close() }
}
