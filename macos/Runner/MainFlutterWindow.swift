import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, FlutterStreamHandler {
  private let preferences = DevicePreferences()
  private let discovery = LocalDiscovery()
  private let files = FileAccessBridge()
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var desktop: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var allowItem: NSMenuItem?
  private var desktopReady = false
  private var quitPending = false
  private(set) var terminationApproved = false
  private var connectionSupported = false

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
      case "connection.identity":
        do { result(FlutterStandardTypedData(bytes: try ConnectionSecurity.identitySeed())) }
        catch { result(FlutterError(code: "identity_unavailable", message: "无法读取设备身份，请检查钥匙串。", details: nil)) }
      case "connection.clock": result(ConnectionSecurity.continuousMicros)
      case "connection.advertise":
        let arguments = call.arguments as? [String: Any]
        result(self.discovery.advertiseConnection(port: arguments?["port"] as? Int, key: arguments?["key"] as? String))
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
    desktop = FlutterMethodChannel(name: "dev.sharehub.client/desktop", binaryMessenger: controller.engine.binaryMessenger)
    desktop?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "closed", message: "窗口已关闭", details: nil)); return }
      switch call.method {
      case "initialize":
        self.connectionSupported = (call.arguments as? [String: Any])?["connectionSupported"] as? Bool == true
        self.installStatusItem()
        guard self.statusItem?.button != nil else {
          result(FlutterError(code: "tray_unavailable", message: "菜单栏入口不可用", details: nil)); return
        }
        self.desktopReady = true
        result(["allowConnections": UserDefaults.standard.bool(forKey: "allowConnections")])
      case "state":
        let allowed = (call.arguments as? [String: Any])?["allowConnections"] as? Bool == true
        self.allowItem?.state = allowed ? .on : .off
        UserDefaults.standard.set(allowed, forKey: "allowConnections")
        result(nil)
      case "appearance.read": result(UserDefaults.standard.string(forKey: "appearance") ?? "system")
      case "appearance.write":
        guard let value = call.arguments as? String, ["system", "light", "dark"].contains(value) else {
          result(FlutterError(code: "invalid_theme", message: "主题无效", details: nil)); return
        }
        UserDefaults.standard.set(value, forKey: "appearance"); result(nil)
      case "exit":
        // Dart has already awaited the complete cleanup transaction. Do not
        // request it again from AppKit's nested termination loop.
        self.completeTermination(); result(nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
      case "prepareExit": self.files.cancelPicker(); result(nil)
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

  private func installStatusItem() {
    guard statusItem == nil else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "串串")
    item.button?.toolTip = "串串 · 后台连接与会话"
    let menu = NSMenu()
    func entry(_ title: String, _ action: Selector) -> NSMenuItem {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self; menu.addItem(entry); return entry
    }
    _ = entry("打开主窗口", #selector(showMainWindow))
    allowItem = entry(connectionSupported ? "允许连接" : "允许连接（当前平台不可用）", #selector(toggleAllow))
    allowItem?.isEnabled = connectionSupported
    menu.autoenablesItems = false
    _ = entry("停止控制（当前无远控会话）", #selector(stopControl))
    menu.addItem(.separator())
    _ = entry("退出串串", #selector(quitApplication))
    item.menu = menu
    statusItem = item
  }

  @objc func showMainWindow() {
    if isMiniaturized { deminiaturize(nil) }
    makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  @objc private func toggleAllow() {
    guard desktopReady, !quitPending, connectionSupported else { return }
    allowItem?.isEnabled = false
    desktop?.invokeMethod("toggleAllow", arguments: nil) { [weak self] _ in
      guard let self else { return }
      self.allowItem?.isEnabled = self.connectionSupported
    }
  }
  @objc private func stopControl() {
    guard desktopReady, !quitPending else { return }
    desktop?.invokeMethod("stopControl", arguments: nil)
  }
  @objc private func quitApplication() { NSApp.terminate(nil) }

  func requestTermination(_ completion: @escaping (Bool) -> Void) {
    guard !quitPending else { completion(false); return }
    if !desktopReady { completion(true); return }
    quitPending = true
    desktop?.invokeMethod("requestExit", arguments: nil) { [weak self] value in
      guard let self else { completion(false); return }
      let allowed = value as? Bool == true
      self.quitPending = false
      if allowed {
        self.completeTermination()
      } else { self.showMainWindow() }
      completion(allowed)
    }
  }

  private func completeTermination() {
    terminationApproved = true
    discovery.stop(); files.close()
    if let status = statusItem { NSStatusBar.system.removeStatusItem(status) }
    statusItem = nil
  }

  override func close() {
    if terminationApproved { super.close(); return }
    if desktopReady, statusItem?.button != nil {
      orderOut(nil) // Retain engine, capture, connections and file tokens.
    } else {
      NSApp.terminate(nil) // Never leave an unreachable process without a tray.
    }
  }
}
