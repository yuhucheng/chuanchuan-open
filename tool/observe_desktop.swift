// Read-only desktop observer for the double-click field test.
//
// It answers "what does the operating system see" without any TCC grant: the
// unified log refuses to run sandboxed, screenshots and UI scripting both need
// permissions this host does not have, but window metadata, process state,
// cumulative CPU time and the display set are all readable.
//
// Every sample is one JSON object on its own line (JSONL), so a whole session
// can be diffed phase by phase afterwards.
//
// Usage:
//   xcrun swift tool/observe_desktop.swift --match "Share Hub" --interval 2 \
//     --duration 1800 --out /tmp/field.jsonl

import AppKit
import CoreGraphics
import Darwin

// MARK: - Options

struct Options {
    var match = "Share Hub"
    var interval = 2.0
    var duration = 1800.0
    var out: String?
    // LaunchServices identity of the app under test. Its `Hidden` flag is the
    // only honest reading of "hidden by Cmd+H" / "minimised away" that works
    // here without extra grants.
    var bundle = "dev.sharehub.client"
    // Owners whose window inventory is aggregated per sample. The recording
    // indicator belongs to the Window Server, so its layer/bounds multiset is
    // recorded to make an idle-vs-capturing diff possible.
    var watchOwners = ["Window Server"]
}

func parseOptions() -> Options {
    var options = Options()
    let argv = CommandLine.arguments
    var index = 1
    while index < argv.count {
        let key = argv[index]
        let value = index + 1 < argv.count ? argv[index + 1] : nil
        // Each flag consumes its value by stepping over it here; the loop then
        // steps over the flag itself. An earlier version advanced the index
        // inside the accessor as well, which skipped every second token.
        switch key {
        case "--match":
            if let value { options.match = value; index += 1 }
        case "--interval":
            if let value, let seconds = Double(value) { options.interval = seconds; index += 1 }
        case "--duration":
            if let value, let seconds = Double(value) { options.duration = seconds; index += 1 }
        case "--out":
            if let value { options.out = value; index += 1 }
        case "--bundle":
            if let value { options.bundle = value; index += 1 }
        default:
            break
        }
        index += 1
    }
    return options
}

// MARK: - Sampling

func boundsText(_ window: [String: Any]) -> String {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return "" }
    func number(_ key: String) -> Double {
        if let d = bounds[key] as? Double { return d }
        if let i = bounds[key] as? Int { return Double(i) }
        return 0
    }
    return String(format: "%.0f,%.0f %.0fx%.0f",
                  number("X"), number("Y"), number("Width"), number("Height"))
}

func processSnapshot(_ pid: pid_t) -> [String: Any] {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
    guard read == size else { return ["cpuUnavailable": true] }
    // libproc reports these in nanoseconds; validated against wall-clock delta
    // in the first field run before any conclusion is drawn from them.
    let cpuSeconds = (Double(info.pti_total_user) + Double(info.pti_total_system)) / 1_000_000_000
    return [
        "cpuSeconds": (cpuSeconds * 1000).rounded() / 1000,
        "rssBytes": Int(info.pti_resident_size),
        "threads": Int(info.pti_threadnum),
    ]
}

func displaySnapshot() -> [[String: Any]] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    let main = CGMainDisplayID()
    return ids.map { id in
        let bounds = CGDisplayBounds(id)
        return [
            "id": Int(id),
            "main": id == main,
            "bounds": String(format: "%.0f,%.0f %.0fx%.0f",
                             bounds.origin.x, bounds.origin.y, bounds.width, bounds.height),
            "mirrored": CGDisplayIsInMirrorSet(id) != 0,
        ]
    }
}

// MARK: - LaunchServices readings

/// Runs a system tool and returns its standard output. Kept tiny and
/// synchronous: a sample is taken every couple of seconds, not in a hot loop.
func runTool(_ path: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// "LSDisplayName"="Google Chrome" -> Google Chrome
func quotedValue(_ line: String) -> String? {
    guard let equals = line.firstIndex(of: "=") else { return nil }
    return String(line[line.index(after: equals)...])
        .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
}

func frontmostName() -> String {
    guard let asn = runTool("/usr/bin/lsappinfo", ["front"])?
        .trimmingCharacters(in: .whitespacesAndNewlines), !asn.isEmpty else { return "" }
    guard let line = runTool("/usr/bin/lsappinfo", ["info", "-only", "name", asn])?
        .split(separator: "\n").first else { return "" }
    return quotedValue(String(line)) ?? ""
}

/// Identity, liveness and hidden state of the app under test, read from
/// LaunchServices. Returns nil when the app is not registered as running.
func launchServicesApp(bundle: String) -> [String: Any]? {
    guard let asn = runTool("/usr/bin/lsappinfo", ["find", "bundleid=\(bundle)"])?
        .trimmingCharacters(in: .whitespacesAndNewlines), !asn.isEmpty,
        let details = runTool("/usr/bin/lsappinfo", ["info", "-only", "hidden,name,pid", asn])
    else { return nil }
    var raw: [String: String] = [:]
    for line in details.split(separator: "\n") {
        let text = String(line).trimmingCharacters(in: .whitespaces)
        guard let equals = text.firstIndex(of: "=") else { continue }
        let key = text[text.startIndex..<equals]
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        raw[key.lowercased()] = String(text[text.index(after: equals)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
    var entry: [String: Any] = ["asn": asn]
    if let name = raw["lsdisplayname"] { entry["name"] = name }
    if let hidden = raw["hidden"] { entry["hidden"] = hidden == "true" }
    if let text = raw["pid"], let pid = Int32(text) {
        let alive = kill(pid, 0) == 0
        entry["pid"] = Int(pid)
        entry["alive"] = alive
        if alive { entry.merge(processSnapshot(pid)) { _, new in new } }
    }
    return entry
}

func sample(_ options: Options, started: Date) -> [String: Any] {
    // Local time on purpose: the timeline is read next to a human's notes.
    let localISO = ISO8601DateFormatter()
    localISO.timeZone = TimeZone.current
    var record: [String: Any] = [
        "tMs": Int(Date().timeIntervalSince(started) * 1000),
        "localTime": localISO.string(from: Date()),
        "displays": displaySnapshot(),
        "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
    ]

    let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] ?? []

    var watched: [String: [String: Int]] = [:]
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        guard options.watchOwners.contains(owner) else { continue }
        let layer = window[kCGWindowLayer as String] as? Int ?? -999
        let onscreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
        let name = window[kCGWindowName as String] as? String ?? ""
        let key = "layer=\(layer)|onscreen=\(onscreen)|name=\(name.isEmpty ? "<redacted>" : name)"
        watched[owner, default: [:]][key, default: 0] += 1
    }
    record["watchedOwners"] = watched

    let needle = options.match.lowercased()
    var appWindows: [[String: Any]] = []
    var ownerTotals: [String: Int] = [:]
    for window in windows {
        let owner = window[kCGWindowOwnerName as String] as? String ?? ""
        ownerTotals[owner, default: 0] += 1
        guard owner.lowercased().contains(needle) else { continue }
        appWindows.append([
            "number": window[kCGWindowNumber as String] as? Int ?? -1,
            "layer": window[kCGWindowLayer as String] as? Int ?? -999,
            "onscreen": (window[kCGWindowIsOnscreen as String] as? Bool) ?? false,
            "alpha": window[kCGWindowAlpha as String] as? Double ?? -1,
            "bounds": boundsText(window),
        ])
    }
    var apps: [[String: Any]] = []
    if let entry = launchServicesApp(bundle: options.bundle) { apps.append(entry) }
    record["app"] = apps
    record["appRunning"] = (apps.first?["alive"] as? Bool) ?? false
    // Unset (not false) when the app is gone: "no reading" must not be mistaken
    // for "measured as visible".
    record["appHidden"] = apps.first?["hidden"] ?? NSNull()
    record["appWindows"] = appWindows
    // Recorded for completeness only. Measured on macOS 26: a status item does
    // NOT appear as an app-owned window, because the system hosts menu bar
    // items outside the app process. An app running with its menu bar entry
    // visible still shows zero high-layer windows here, so this set must never
    // be read as evidence that the menu bar entry exists or is missing.
    record["appHighLayerWindows"] = appWindows.filter { ($0["layer"] as? Int ?? 0) >= 20 }
    record["appWindowsOnscreen"] = appWindows.filter { ($0["onscreen"] as? Bool) ?? false }.count
    // Kept small on purpose: only counts, so the JSONL stays diffable by hand.
    record["ownerTotals"] = ownerTotals
    return record
}

// MARK: - Entry

let options = parseOptions()
var sink: FileHandle?
if let path = options.out {
    FileManager.default.createFile(atPath: path, contents: nil)
    sink = FileHandle(forWritingAtPath: path)
    // Failing quietly here once cost a whole debugging detour: the timeline
    // looked like it was running while nothing reached disk.
    if sink == nil {
        FileHandle.standardError.write(Data("无法写入 --out 文件: \(path)\n".utf8))
        exit(2)
    }
}
FileHandle.standardError.write(Data("观测器启动: match=\(options.match) interval=\(options.interval)s duration=\(options.duration)s out=\(options.out ?? "<仅标准输出>")\n".utf8))

let started = Date()
writeSample(options, started: started, sink: sink)
while Date().timeIntervalSince(started) + options.interval <= options.duration {
    Thread.sleep(forTimeInterval: options.interval)
    writeSample(options, started: started, sink: sink)
}

func writeSample(_ options: Options, started: Date, sink: FileHandle?) {
    let record = sample(options, started: started)
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    sink?.write(line.data(using: .utf8)!)
}
