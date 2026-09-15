import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, FlutterStreamHandler {
  private let preferences = DevicePreferences()
  private let discovery = LocalDiscovery()
  private let files = FileAccessBridge()
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?

  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1180, height: 780))
    minSize = NSSize(width: 860, height: 640)
    title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? "Share Hub"
    center()
    RegisterGeneratedPlugins(registry: controller)
    methods = FlutterMethodChannel(name: "dev.sharehub.client/platform", binaryMessenger: controller.engine.binaryMessenger)
    events = FlutterEventChannel(name: "dev.sharehub.client/discovery", binaryMessenger: controller.engine.binaryMessenger)
    events?.setStreamHandler(self)
    methods?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "客户端已关闭。", details: nil)); return }
      if call.method.hasPrefix("files.") {
        self.files.handle(call, window: self, result: result)
        return
      }
      switch call.method {
      case "loadDevice":
        result(["id": self.preferences.discoveryID, "name": self.preferences.name])
      case "setDeviceName":
        guard let name = call.arguments as? String else { result(FlutterError(code: "invalid_name", message: "请输入设备名称。", details: nil)); return }
        do {
          try self.preferences.setName(name)
          result(["id": self.preferences.discoveryID, "name": self.preferences.name])
        } catch {
          result(FlutterError(code: "invalid_name", message: "设备名称不能为空、包含控制字符或超过 128 字节。", details: nil))
        }
      case "permissions": result(SystemPermissions.snapshot)
      case "requestScreenRecording": result(SystemPermissions.requestScreenRecording())
      case "openSettings": result(SystemPermissions.openSettings(call.arguments as? String ?? ""))
      case "startDiscovery":
        do {
          try self.discovery.start(id: self.preferences.discoveryID, name: self.preferences.name)
          result(nil)
        } catch {
          self.discovery.stop()
          result(FlutterError(code: "discovery_failed", message: "局域网发现启动失败，请检查网络后重试。", details: nil))
        }
      case "stopDiscovery": self.discovery.stop(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    discovery.onChange = { events($0) }
    events(discovery.snapshot)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    discovery.onChange = nil
    discovery.stop()
    return nil
  }

  override func close() {
    discovery.stop()
    files.close()
    super.close()
  }
}
