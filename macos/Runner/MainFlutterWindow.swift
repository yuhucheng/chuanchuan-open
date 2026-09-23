import Cocoa
import CoreFoundation
import FlutterMacOS

class MainFlutterWindow: NSWindow, FlutterStreamHandler, NSDraggingDestination {
  private let preferences = DevicePreferences()
  private let discovery = LocalDiscovery()
  private let files = FileAccessBridge()
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var desktop: FlutterMethodChannel?
  private var statusItem: NSStatusItem?
  private var allowItem: NSMenuItem?
  private var stopControlItem: NSMenuItem?
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
    files.configureFileDrop(messenger: controller.engine.binaryMessenger)
    registerForDraggedTypes([.fileURL])
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
        result([
          "allowConnections": UserDefaults.standard.bool(forKey: "allowConnections"),
          "controlNoticeEnabled": UserDefaults.standard.object(forKey: "controlNoticeEnabled") as? Bool ?? true,
        ])
      case "state":
        let state = call.arguments as? [String: Any]
        let allowed = state?["allowConnections"] as? Bool == true
        let controlActive = state?["controlActive"] as? Bool == true
        let noticeEnabled = state?["controlNoticeEnabled"] as? Bool != false
        self.allowItem?.state = allowed ? .on : .off
        self.stopControlItem?.title = controlActive ? "停止控制" : "停止控制（当前无远控会话）"
        self.stopControlItem?.isEnabled = controlActive
        self.statusItem?.button?.toolTip = controlActive && noticeEnabled
          ? "串串 · 正在被远程控制" : "串串 · 后台连接与会话"
        UserDefaults.standard.set(allowed, forKey: "allowConnections")
        UserDefaults.standard.set(noticeEnabled, forKey: "controlNoticeEnabled")
        result(nil)
      case "appearance.read": result(UserDefaults.standard.string(forKey: "appearance") ?? "system")
      case "appearance.write":
        guard let value = call.arguments as? String, ["system", "light", "dark"].contains(value) else {
          result(FlutterError(code: "invalid_theme", message: "主题无效", details: nil)); return
        }
        UserDefaults.standard.set(value, forKey: "appearance"); result(nil)
      case "controlClipboard.read":
        if let stored = UserDefaults.standard.object(forKey: "controlClipboardSyncEnabled") {
          guard let number = stored as? NSNumber,
                CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() else {
            result(FlutterError(code: "preferences_failed", message: "剪贴板设置已损坏", details: nil)); return
          }
          result(number.boolValue)
        } else {
          result(true)
        }
      case "controlClipboard.write":
        guard let enabled = call.arguments as? Bool else {
          result(FlutterError(code: "invalid_preference", message: "需要布尔值", details: nil)); return
        }
        UserDefaults.standard.set(enabled, forKey: "controlClipboardSyncEnabled")
        result(nil)
      case "exit":
        // Dart has already awaited the complete cleanup transaction. Do not
        // request it again from AppKit's nested termination loop.
        self.completeTermination(); result(nil)
        DispatchQueue.main.async { NSApp.terminate(nil) }
      case "prepareExit": self.files.cancelPicker(); result(nil)
      case "system.indicators": result(Self.screenRecordingIndicators())
      case "window.state": result(self.windowState())
      case "window.action":
        // Acceptance-only window control. The shipped UI never calls this; it
        // exists because the host has no accessibility permission here, so the
        // background matrix (minimize/hide/close-to-background/reopen) cannot be
        // driven through real clicks. Each action reuses the same code path as
        // the corresponding user gesture.
        guard let action = (call.arguments as? [String: Any])?["action"] as? String else {
          result(FlutterError(code: "invalid_action", message: "缺少窗口动作。", details: nil)); return
        }
        switch action {
        case "minimize": self.miniaturize(nil)
        case "deminiaturize": self.deminiaturize(nil)
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhide(nil)
        case "close": self.close()
        case "reopen": self.showMainWindow()
        default:
          result(FlutterError(code: "invalid_action", message: "不支持的窗口动作。", details: nil)); return
        }
        result(self.windowState())
      default: result(FlutterMethodNotImplemented)
      }
    }
    super.awakeFromNib()
  }

  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !quitPending, !terminationApproved else { return [] }
    return files.dropOperation(sender)
  }
  func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
  func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard draggingEntered(sender) == .copy, let view = contentViewController?.view else { return false }
    return files.acceptDrop(sender, view: view)
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

  /// Observable background/tray state, used by the acceptance entry to record
  /// the macOS background matrix without accessibility-driven UI automation.
  private func windowState() -> [String: Any] {
    var trayItems: [[String: Any]] = []
    if let menu = statusItem?.menu {
      trayItems = menu.items.filter { !$0.isSeparatorItem }.map { item in
        [
          "title": item.title,
          "enabled": item.isEnabled,
          "checked": item.state == .on,
        ]
      }
    }
    return [
      "visible": isVisible,
      "miniaturized": isMiniaturized,
      "key": isKeyWindow,
      "onscreen": occlusionState.contains(.visible),
      "trayInstalled": statusItem != nil,
      "trayButtonAvailable": statusItem?.button != nil,
      "trayItems": trayItems,
      "desktopReady": desktopReady,
      "terminationApproved": terminationApproved,
      "quitPending": quitPending,
    ]
  }

  /// Best-effort enumeration of system windows that look like the screen
  /// recording indicator. macOS draws that indicator outside the app, so the
  /// public window list is the only handle. An empty result is recorded as an
  /// unsupported observation, never as "the system shows no indicator".
  private static func screenRecordingIndicators() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return []
    }
    let needles = ["screen", "capture", "record", "录制", "control center", "window server"]
    return windows.compactMap { info in
      let owner = info[kCGWindowOwnerName as String] as? String ?? ""
      let name = info[kCGWindowName as String] as? String ?? ""
      let haystack = "\(owner) \(name)".lowercased()
      guard needles.contains(where: { haystack.contains($0) }) else { return nil }
      var bounds: [String: Any] = [:]
      if let raw = info[kCGWindowBounds as String] as? [String: Any] {
        bounds = [
          "x": (raw["X"] as? NSNumber)?.doubleValue ?? 0,
          "y": (raw["Y"] as? NSNumber)?.doubleValue ?? 0,
          "width": (raw["Width"] as? NSNumber)?.doubleValue ?? 0,
          "height": (raw["Height"] as? NSNumber)?.doubleValue ?? 0,
        ]
      }
      return [
        "owner": owner,
        "name": name,
        "layer": info[kCGWindowLayer as String] as? Int ?? -1,
        "bounds": bounds,
      ]
    }
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
    stopControlItem = entry("停止控制（当前无远控会话）", #selector(stopControl))
    stopControlItem?.isEnabled = false
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
    unregisterDraggedTypes()
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
