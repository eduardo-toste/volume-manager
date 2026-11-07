import CoreAudio
import Darwin
import Foundation
import CAtomics
import SpikeCore

/// Stop request set by the signal handlers (atomic flag, see CAtomics).
final class StopFlag: @unchecked Sendable {
    private let cell = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    init() { cell.initialize(to: 0) }
    var isSet: Bool { vm_load_u32(cell) != 0 }
    func set() { vm_store_u32(cell, 1) }
}
let stopFlag = StopFlag()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    print(
        """
        usage:
          vmctl processes
          vmctl devices
          vmctl master [0..1]
          vmctl set <bundleID> --volume <0..1> [--mute] [--device <UID>] [--duration <s>]
          vmctl stress-taps <n> [--app <bundleID>]
        """)
    exit(2)
}

func parseUnit(_ s: String, _ name: String) -> Float {
    guard let v = Float(s), v.isFinite, v >= 0, v <= 1 else { fail("\(name) must be a number in 0...1") }
    return v
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
    return args[args.index(after: i)]
}

func installSignalHandlers() -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { stopFlag.set() }
        src.resume()
        return src
    }
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
    return s(u.ru_utime) + s(u.ru_stime)
}

func pickOutput(_ uid: String?) throws -> OutputDevice {
    let devices = try outputDevices()
    if let uid {
        guard let d = devices.first(where: { $0.uid == uid }) else { fail("no output device with UID \(Sanitize.text(uid)); see `vmctl devices`") }
        return d
    }
    guard let d = devices.first(where: { $0.isDefault }) else { fail("no default output device") }
    return d
}

/// Revalidates PIDs just before tapping (SPEC 12.9.4): PID, bundle ID and path must still match.
func revalidated(_ group: AppGroup) -> [AudioObjectID] {
    group.procs.compactMap { p in
        guard let pid: pid_t = try? getValue(p.objectID, address(kAudioProcessPropertyPID), zero: pid_t(0)),
            pid == p.pid, executablePath(of: pid) == p.path
        else { return nil }
        return p.objectID
    }
}

func runSet(_ args: [String]) throws {
    guard let bundle = args.first, !bundle.hasPrefix("--") else { usage() }
    let volume = option("--volume", in: args).map { parseUnit($0, "--volume") } ?? 1
    let muted = args.contains("--mute")
    let duration = option("--duration", in: args).flatMap(Double.init) ?? 30
    guard duration > 0, duration <= 3600 else { fail("--duration must be in 1...3600") }
    let output = try pickOutput(option("--device", in: args))

    guard let group = findGroup(try listAudioProcesses(), matching: bundle) else {
        fail("no audio process group for \(Sanitize.text(bundle)); is the app producing audio? see `vmctl processes`")
    }
    let objects = revalidated(group)
    guard !objects.isEmpty, objects.count == group.procs.count else { fail("process list changed while resolving the app; try again") }
    print("tapping \(group.name): pids \(group.procs.map { String($0.pid) }.joined(separator: ",")) -> \(output.name) [\(output.uid)] volume=\(volume) mute=\(muted)")

    let sources = installSignalHandlers()
    _ = sources
    let session = TapSession()
    do {
        try session.start(processObjectIDs: objects, output: output, volume: volume, muted: muted)
    } catch {
        fail("\(error) -- original audio is untouched")
    }
    defer { session.stop() }
    print("tap format:    \(session.tapFormatDescription)")
    print("output format: \(session.outputFormatDescription)")

    let startTime = Date()
    var lastFrames: UInt64 = 0
    var lastProgress = Date()
    var lastReport = Date()
    var lastCPU = cpuSeconds()
    while !stopFlag.isSet, Date().timeIntervalSince(startTime) < duration {
        Thread.sleep(forTimeInterval: 0.25)
        let now = Date()
        let frames = session.state.frames
        if frames != lastFrames {
            lastFrames = frames
            lastProgress = now
        } else if now.timeIntervalSince(lastProgress) >= 2 {
            let stillPlaying = ((try? listAudioProcesses()) ?? []).contains { p in objects.contains(p.objectID) && p.isRunningOutput }
            if stillPlaying {
                print("WATCHDOG: no frames for 2 s while app is still playing; destroying tap (original sound returns)")
                return
            }
            lastProgress = now
        }
        if now.timeIntervalSince(lastReport) >= 5 {
            let cpu = cpuSeconds()
            let pct = (cpu - lastCPU) / now.timeIntervalSince(lastReport) * 100
            print(String(format: "frames=%llu  cpu=%.2f%%  input-peak=%.6f", frames, pct, session.state.inputPeak))
            lastCPU = cpu
            lastReport = now
        }
    }
    print("stopping; frames processed: \(session.state.frames)")
}

func runStress(_ args: [String]) throws {
    guard let first = args.first, let n = Int(first), n > 0, n <= 1000 else { usage() }
    let procs = try listAudioProcesses()
    let groups = groupProcesses(procs)
    let target: AppGroup?
    if let id = option("--app", in: args) { target = findGroup(procs, matching: id) } else { target = groups.first { $0.isPlaying } }
    guard let group = target else { fail("no playing app found; start audio (e.g. afplay) or pass --app") }
    let output = try pickOutput(nil)
    let before = Set(try allDeviceIDs())
    var failures = 0
    for i in 1...n {
        let session = TapSession()
        do {
            try session.start(processObjectIDs: revalidated(group), output: output, volume: 1, muted: false, startIO: i % 2 == 0)
            usleep(20_000)
        } catch {
            failures += 1
            print("iteration \(i): \(error)")
            if failures >= 3 { print("too many failures; stopping"); break }
        }
        session.stop()
    }
    usleep(300_000)
    let after = Set(try allDeviceIDs())
    let leaked = after.subtracting(before)
    print("stress done on \(group.name): n=\(n) failures=\(failures) devices before=\(before.count) after=\(after.count) leaked=\(leaked.count)")
    print(leaked.isEmpty ? "PASS: no leaked aggregate devices" : "FAIL: leaked device IDs \(leaked.sorted())")
    if !leaked.isEmpty || failures > 0 { exit(1) }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { usage() }
    let rest = Array(args.dropFirst())
    switch command {
    case "processes":
        try printProcesses()
    case "devices":
        print("ID\tDEFAULT\tSW-VOL\tRATE\tUID\tNAME")
        for d in try outputDevices() {
            print("\(d.id)\t\(d.isDefault ? "yes" : "no")\t\(d.hasSoftwareVolume ? "yes" : "no")\t\(Int(d.sampleRate))\t\(d.uid)\t\(d.name)")
        }
    case "master":
        let dev = try defaultOutputID()
        if let v = rest.first {
            try setMasterVolume(dev, parseUnit(v, "volume"))
        }
        print(String(format: "default output volume: %.3f", try masterVolume(dev)))
    case "set":
        try runSet(rest)
    case "stress-taps":
        try runStress(rest)
    default:
        usage()
    }
} catch {
    fail("\(error)")
}
