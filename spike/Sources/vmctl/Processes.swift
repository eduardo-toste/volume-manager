import AppKit
import CoreAudio
import Darwin
import Foundation
import SpikeCore

/// Private libsystem symbol (the one Activity Monitor / launchd use). Declared ONLY for the spike (SPEC 4.1 step 2);
/// linked at build time, never via dlopen/dlsym. See REPORT.md for the private-API risk.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
func responsibilityGetPidResponsible(forPid pid: pid_t) -> pid_t

struct AudioProc {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let path: String?
    let isRunningOutput: Bool
    let responsiblePID: pid_t?
    let responsiblePath: String?
    let owner: AppOwner
    let method: GroupingMethod
}

struct AppGroup {
    let key: String
    let name: String
    let ownerBundleID: String?
    let procs: [AudioProc]
    var isPlaying: Bool { procs.contains { $0.isRunningOutput } }
}

func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return Sanitize.text(String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self), limit: 1024)
}

func listAudioProcesses() throws -> [AudioProc] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let ids = try getArray(system, address(kAudioHardwarePropertyProcessObjectList), zero: AudioObjectID(0))
    let myPID = getpid()
    var result: [AudioProc] = []
    for id in ids {
        guard let pid: pid_t = try? getValue(id, address(kAudioProcessPropertyPID), zero: pid_t(0)), pid != myPID else { continue }
        let bundle = (try? getString(id, address(kAudioProcessPropertyBundleID))).flatMap { $0.isEmpty ? nil : Sanitize.text($0) }
        let running = ((try? getValue(id, address(kAudioProcessPropertyIsRunningOutput), zero: UInt32(0))) ?? 0) != 0
        let path = executablePath(of: pid)
        var respPID: pid_t?
        var respPath: String?
        let r = responsibilityGetPidResponsible(forPid: pid)
        if r > 0, r != pid {
            respPID = r
            respPath = executablePath(of: r)
        }
        let (owner, method) = AppGrouping.resolve(executablePath: path, responsiblePath: respPath, bundleID: bundle)
        result.append(
            AudioProc(
                objectID: id, pid: pid, bundleID: bundle, path: path, isRunningOutput: running,
                responsiblePID: respPID, responsiblePath: respPath, owner: owner, method: method))
    }
    return result
}

func groupProcesses(_ procs: [AudioProc]) -> [AppGroup] {
    let running = NSWorkspace.shared.runningApplications
    var order: [String] = []
    var buckets: [String: [AudioProc]] = [:]
    for p in procs {
        let key: String
        switch p.owner {
        case .app(let path): key = "app:" + path
        case .bundlePrefix(let prefix):
            // System daemons/extensions without a visible app are excluded (SPEC 4.1).
            if let path = p.path, path.hasPrefix("/System/") || path.hasPrefix("/usr/") { continue }
            key = "id:" + prefix
        case .none: continue
        }
        if buckets[key] == nil { order.append(key) }
        buckets[key, default: []].append(p)
    }
    return order.compactMap { key in
        guard let members = buckets[key], let first = members.first else { return nil }
        switch first.owner {
        case .app(let path):
            let bundle = Bundle(path: path)
            let live = running.first { $0.bundleURL?.path == path }
            let name = live?.localizedName ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return AppGroup(key: key, name: Sanitize.text(name), ownerBundleID: bundle?.bundleIdentifier.map { Sanitize.text($0) }, procs: members)
        case .bundlePrefix(let prefix):
            return AppGroup(key: key, name: prefix, ownerBundleID: prefix, procs: members)
        case .none:
            return nil
        }
    }
}

/// Matches by owner bundle ID / member bundle ID. `pid:<N>` targets one process (spike-only, for test tones like afplay).
func findGroup(_ procs: [AudioProc], matching id: String) -> AppGroup? {
    if id.hasPrefix("pid:"), let pid = pid_t(id.dropFirst(4)) {
        let members = procs.filter { $0.pid == pid }
        return members.isEmpty ? nil : AppGroup(key: "pid:\(pid)", name: "pid \(pid)", ownerBundleID: nil, procs: members)
    }
    return groupProcesses(procs).first { g in
        g.ownerBundleID?.caseInsensitiveCompare(id) == .orderedSame
            || g.procs.contains { $0.bundleID?.caseInsensitiveCompare(id) == .orderedSame }
    }
}

func printProcesses() throws {
    let procs = try listAudioProcesses()
    print("== Audio processes (\(procs.count)) ==")
    print("PID     RUN  GROUP-BY     BUNDLE-ID  |  EXECUTABLE  ->  OWNER")
    for p in procs {
        let ownerText: String
        switch p.owner {
        case .app(let path): ownerText = path
        case .bundlePrefix(let s): ownerText = "bundle-prefix \(s)"
        case .none: ownerText = "-"
        }
        let resp = p.responsiblePID.map { " resp=\($0)" } ?? ""
        print("\(p.pid)\t\(p.isRunningOutput ? "yes" : "no ")  \(p.method.rawValue)\t\(p.bundleID ?? "-")  |  \(p.path ?? "-")\(resp)  ->  \(ownerText)")
    }
    print("\n== Grouped by app ==")
    for g in groupProcesses(procs) {
        let pids = g.procs.map { String($0.pid) }.joined(separator: ",")
        print("\(g.isPlaying ? "[PLAYING]" : "[idle]   ") \(g.name) <\(g.ownerBundleID ?? "?")>  pids: \(pids)")
    }
}
