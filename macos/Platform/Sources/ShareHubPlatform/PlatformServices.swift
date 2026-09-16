import AppKit
import ApplicationServices
import Network
import Security
import SystemConfiguration

/// This identifier is only for discovery deduplication. It is NOT a device key,
/// activation credential, or proof of identity.
public final class DevicePreferences {
    private let defaults: UserDefaults
    public let discoveryID: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: "discoveryID"), UUID(uuidString: saved) != nil {
            discoveryID = saved
        } else {
            discoveryID = UUID().uuidString.lowercased()
            defaults.set(discoveryID, forKey: "discoveryID")
        }
    }

    public var name: String {
        defaults.string(forKey: "deviceName") ?? "我的 Mac"
    }

    public func setName(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PlatformFailure.invalidName
        }
        defaults.set(value, forKey: "deviceName")
    }
}

public enum PlatformFailure: Error {
    case invalidName
}

public struct DiscoveredDevice: Equatable {
    public let id: String
    public let name: String
    public let platform: String
    public let connection: [String: String]

    public init?(record: [String: String], localID: String) {
        guard record["v"] == "1", let id = record["id"], UUID(uuidString: id) != nil,
              id.lowercased() != localID.lowercased(), let name = record["name"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let platform = record["platform"], ["macos", "windows", "android"].contains(platform) else {
            return nil
        }
        self.id = id.lowercased()
        self.name = name
        self.platform = platform
        var endpoint: [String: String] = [:]
        if let host = record["host"], host.utf8.count <= 253, host.hasSuffix(".local"),
           let port = record["port"], let number = Int(port), (1...65535).contains(number),
           let key = record["key"], key.utf8.count == 44 {
            endpoint = ["host": host, "port": port, "key": key]
        }
        self.connection = endpoint
    }

    public var dictionary: [String: String] {
        ["id": id, "name": name, "platform": platform].merging(connection) { _, new in new }
    }
}

/// All state and callbacks are confined to the main queue. Discovery is opt-in,
/// limited to local Bonjour and never establishes a trusted session.
public final class LocalDiscovery {
    public static let serviceType = "_sharehub-dev._tcp"
    public var onChange: (([String: Any]) -> Void)?
    private var connectionRecord: [String: String] = [:]
    private var presence: [String: String] = [:]
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var generation = 0
    private var listenerReady = false
    private var browserReady = false
    private var state = "stopped"
    private var devices: [DiscoveredDevice] = []
    private var message: String?

    public init() {}

    public var snapshot: [String: Any] {
        var result: [String: Any] = ["state": state, "devices": devices.map(\.dictionary)]
        if let message { result["message"] = message }
        return result
    }

    public func start(id: String, name: String) throws {
        stop()
        let token = generation
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        var service = NWListener.Service(name: id, type: Self.serviceType, domain: "local.")
        presence = ["v": "1", "id": id, "name": name, "platform": "macos"]
        service.txtRecordObject = NWTXTRecord(presence.merging(connectionRecord) { _, new in new })
        listener.service = service
        // This milestone advertises presence only. No inbound protocol exists,
        // so accepted sockets are immediately closed without reading input.
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { [weak self] value in
            guard let self, self.generation == token else { return }
            switch value {
            case .ready: self.listenerReady = true; self.updateState()
            case .waiting: self.listenerReady = false; self.waiting()
            case .failed: self.fail()
            default: break
            }
        }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] value in
            guard let self, self.generation == token else { return }
            switch value {
            case .ready: self.browserReady = true; self.updateState()
            case .waiting: self.browserReady = false; self.waiting()
            case .failed: self.fail()
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == token else { return }
            var found: [String: DiscoveredDevice] = [:]
            for result in results {
                guard found.count < 128, case .bonjour(let txt) = result.metadata else { continue }
                var values: [String: String] = [:]
                for key in ["v", "id", "name", "platform", "host", "port", "key"] { values[key] = txt[key] }
                guard let device = DiscoveredDevice(record: values, localID: id) else { continue }
                found[device.id] = device
            }
            self.devices = found.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
            self.emit()
        }
        state = "starting"
        emit()
        listener.start(queue: .main)
        browser.start(queue: .main)
    }

    public func advertiseConnection(port: Int?, key: String?) -> String? {
        connectionRecord = [:]
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
        if let port, let key, let host, (1...65535).contains(port) {
            connectionRecord = ["host": host, "port": String(port), "key": key]
        }
        if var service = listener?.service {
            service.txtRecordObject = NWTXTRecord(presence.merging(connectionRecord) { _, new in new })
            listener?.service = service
        }
        return host
    }

    public func stop() {
        generation += 1
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        listenerReady = false
        browserReady = false
        devices = []
        message = nil
        state = "stopped"
        emit()
    }

    private func updateState() {
        guard listenerReady && browserReady else { return }
        state = "searching"
        message = nil
        emit()
    }

    private func waiting() {
        state = "waiting"
        devices = []
        message = "发现暂不可用，请检查网络连接与系统的本地网络权限。"
        emit()
    }

    private func fail() {
        stop()
        state = "failed"
        message = "局域网发现启动失败，请检查本地网络权限后重试。"
        emit()
    }

    private func emit() { onChange?(snapshot) }
}

public enum SystemPermissions {
    public static var snapshot: [String: Bool] {
        ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
    }

    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    public static func openSettings(_ permission: String) -> Bool {
        let panes = ["screenRecording": "Privacy_ScreenCapture", "accessibility": "Privacy_Accessibility",
                     "localNetwork": "Privacy_LocalNetwork"]
        guard let pane = panes[permission], let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Identity seed is unrelated to the app's development signing certificate.
/// Authorization leases remain in memory and are never restored from Keychain.
public enum ConnectionSecurity {
    public static func identitySeed() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.sharehub.client.connection.v1",
            kSecAttrAccount as String: "ed25519-seed"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw ConnectionSecurityError.identityUnavailable }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConnectionSecurityError.identityUnavailable
        }
        let data = Data(bytes)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw ConnectionSecurityError.identityUnavailable
        }
        return data
    }

    /// mach_continuous_time includes system sleep and ignores wall-clock edits.
    public static var continuousMicros: UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let divisor = UInt64(info.denom) * 1000
        return (ticks / divisor) * UInt64(info.numer)
            + ((ticks % divisor) * UInt64(info.numer)) / divisor
    }
}
public enum ConnectionSecurityError: Error { case identityUnavailable }
