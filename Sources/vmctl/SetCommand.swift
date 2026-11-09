import Darwin
import Foundation
import VolumeAudio
import VolumeCore

/// `vmctl set` and `vmctl stress-taps`: the commands that create taps.
enum TapCommands {
  static func set(_ services: Services, arguments: [String]) async throws {
    let parsed = try Arguments(
      arguments, options: ["volume", "device", "duration"], flags: ["mute"])
    guard parsed.positional.count == 1, let targetText = parsed.positional.first else {
      throw UsageError(
        "usage: vmctl set <bundleID|pid:N> [--volume 0..1] [--mute] [--device UID] [--duration SECONDS]"
      )
    }
    let volume = try parsed.number("volume", in: 0...1, default: 1) ?? 1
    let duration = try parsed.number("duration", in: 0.1...3600, default: 30) ?? 30
    let target = try services.resolveTarget(targetText)
    let snapshot = await services.system.currentState()
    let deviceUID = try resolveDevice(parsed.value("device"), snapshot: snapshot)
    let gain = VolumeCurve.gain(forVolume: volume)
    let muted = parsed.flag("mute")

    let controller = CoreAudioAppController(catalog: services.catalog, identity: target.identity)
    let log = FailureLog()
    let failures = controller.failures()
    let collector = Task { for await failure in failures { log.add(failure) } }
    installSignalHandlers(controller)

    print(
      "target: \(target.label) pids \(target.app.pids) -> device \(ConsoleText.safe(deviceUID))")
    print("volume \(volume) (gain \(gain)), \(muted ? "MUTED" : "not muted"), for \(duration) s")
    let desired = DesiredAppAudio(
      app: target.app, gain: gain, muted: muted, targetDeviceUID: deviceUID)
    await controller.reconcile(desired: [desired])
    let initial = await controller.diagnostics()
    guard let first = initial.first else {
      print("RESULT: no tap was created. failures: \(describe(log.all))")
      await controller.restoreAll()
      collector.cancel()
      return
    }
    print("tap format:    \(first.tapFormat)")
    print("output format: \(first.outputFormat)")

    let startCPU = cpuSeconds()
    let start = ContinuousClock.now
    var lastFrames: UInt64 = 0
    var elapsed = 0.0
    while elapsed < duration {
      try await Task.sleep(for: .seconds(min(1, duration - elapsed)))
      elapsed = (ContinuousClock.now - start) / .seconds(1)
      let now = await controller.diagnostics().first
      guard let now else {
        print("[\(String(format: "%5.1f", elapsed)) s] tap is gone: \(describe(log.all))")
        break
      }
      print(
        "[\(String(format: "%5.1f", elapsed)) s] frames +\(now.framesProcessed - lastFrames) "
          + "(total \(now.framesProcessed)), signal seen: \(now.hasSeenSignal)")
      lastFrames = now.framesProcessed
    }
    let final = await controller.diagnostics().first
    let cpu = (cpuSeconds() - startCPU) / max(elapsed, 0.001) * 100
    await controller.restoreAll()
    collector.cancel()
    print(
      "RESULT: frames \(final?.framesProcessed ?? lastFrames), CPU \(String(format: "%.2f", cpu)) % of one core"
    )
    print("        signal ever seen: \(final?.hasSeenSignal ?? false)")
    print("        failures: \(describe(log.all))")
    print("tap destroyed; the app plays normally again")
  }

  static func stress(_ services: Services, arguments: [String]) async throws {
    let parsed = try Arguments(arguments, options: ["app", "device"])
    guard parsed.positional.count == 1, let countText = parsed.positional.first,
      let count = Int(countText), (1...1000).contains(count)
    else { throw UsageError("usage: vmctl stress-taps <1..1000> --app <bundleID|pid:N>") }
    guard let appText = parsed.value("app") else {
      throw UsageError("stress-taps needs an explicit --app (never guesses a target)")
    }
    let target = try services.resolveTarget(appText)
    let snapshot = await services.system.currentState()
    let deviceUID = try resolveDevice(parsed.value("device"), snapshot: snapshot)
    let controller = CoreAudioAppController(catalog: services.catalog, identity: target.identity)
    installSignalHandlers(controller)
    let desired = DesiredAppAudio(
      app: target.app, gain: 0.25, muted: false, targetDeviceUID: deviceUID)
    let before = AudioDiagnostics.deviceCount()
    let beforeUIDs = Set(AudioDiagnostics.deviceUIDs())
    var failedCycles = 0
    for _ in 0..<count {
      await controller.reconcile(desired: [desired])
      if await controller.diagnostics().isEmpty { failedCycles += 1 }
      await controller.restoreAll()
    }
    // Core Audio finishes destroying the last aggregate device a moment after the call returns.
    try await Task.sleep(for: .milliseconds(1500))
    let after = AudioDiagnostics.deviceCount()
    let extra = Set(AudioDiagnostics.deviceUIDs()).subtracting(beforeUIDs)
    if !extra.isEmpty {
      print("devices that appeared: \(extra.sorted().map { ConsoleText.safe($0) })")
    }
    print("cycles: \(count), failed: \(failedCycles)")
    print("devices before: \(before), after: \(after), leaked: \(after - before)")
    if after != before || failedCycles > 0 {
      throw ProblemError("stress-taps found problems (leaked devices or failed cycles)")
    }
  }

  /// `vmctl restore`: taps live and die with the process that made them, so this stops the
  /// other running `vmctl` processes (each one destroys its taps on SIGTERM).
  static func restore() async throws {
    let mine = getpid()
    var ownBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let ownLength = proc_pidpath(mine, &ownBuffer, UInt32(ownBuffer.count))
    let ownPath =
      ownLength > 0
      ? String(
        decoding: ownBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      : ""
    var stopped = 0
    let capacity = Int(proc_listallpids(nil, 0))
    var pids = [pid_t](repeating: 0, count: max(capacity, 1) + 64)
    let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    for pid in pids.prefix(Int(max(bytes, 0))) where pid > 0 && pid != mine {
      var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
      guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
      let path = String(
        decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard isOurVmctl(path: path, own: ownPath) else { continue }
      if kill(pid, SIGTERM) == 0 { stopped += 1 }
    }
    print(
      "stopped \(stopped) other vmctl process(es); their taps are destroyed and the apps are back to normal"
    )
    print(
      "(Volume Manager itself restores through its own menu; killing a process always returns the sound.)"
    )
  }

  // MARK: Helpers

  /// Only this project's vmctl: the dev bundle, or the very binary that is running now.
  private static func isOurVmctl(path: String, own: String) -> Bool {
    path.hasSuffix("/vmctl-dev.app/Contents/MacOS/vmctl") || (!own.isEmpty && path == own)
  }

  private static func resolveDevice(_ requested: String?, snapshot: AudioSystemSnapshot) throws
    -> String
  {
    if let requested {
      guard snapshot.devices.contains(where: { $0.uid == requested }) else {
        throw UsageError(
          "no output device with UID '\(ConsoleText.safe(requested))' (see: vmctl devices)")
      }
      return requested
    }
    guard let uid = snapshot.defaultOutputUID else {
      throw UsageError("there is no default output device")
    }
    return uid
  }

  private static func describe(_ failures: [AppAudioFailure]) -> String {
    failures.isEmpty ? "none" : failures.map { "\($0.reason)" }.joined(separator: ", ")
  }

  /// SIGINT and SIGTERM destroy every tap before exiting.
  private static func installSignalHandlers(_ controller: CoreAudioAppController) {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      // The handler keeps its own source alive for the life of the process.
      source.setEventHandler { [source] in
        _ = source
        Task {
          await controller.restoreAll()
          print("\nsignal received: taps destroyed")
          exit(0)
        }
      }
      source.resume()
    }
  }
}
