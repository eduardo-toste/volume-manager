import Foundation
import VolumeAudio
import VolumeCore

/// Read-only commands: devices, processes, master (without a value), probe-permission.
enum ReadCommands {
  static func devices(_ services: Services) async throws {
    let snapshot = await services.system.currentState()
    print("DEFAULT  VOL  KIND       FORMAT                                   UID  |  NAME")
    for device in snapshot.devices {
      let isDefault = device.uid == snapshot.defaultOutputUID ? "yes" : "no "
      let format = AudioDiagnostics.outputFormat(ofDeviceUID: device.uid) ?? "?"
      let padded = format.padding(toLength: 40, withPad: " ", startingAt: 0)
      print(
        "\(isDefault)      \(device.hasVolumeControl ? "yes" : "no ")  "
          + "\(device.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) "
          + "\(padded) \(ConsoleText.safe(device.uid))  |  \(ConsoleText.safe(device.name))")
    }
    print("\(AudioDiagnostics.deviceCount()) audio devices in total (including inputs)")
  }

  static func processes(_ services: Services) async throws {
    let processes = services.catalog.processes()
    print("== Audio processes (\(processes.count)) ==")
    for process in processes {
      print(ConsoleText.line(for: process))
    }
    print("\n== Grouped by app (what the mixer would show) ==")
    for app in services.groups(processes) {
      print(ConsoleText.line(for: app))
    }
  }

  static func master(_ services: Services, arguments: [String]) async throws {
    let parsed = try Arguments(arguments)
    try parsed.requirePositional(atMost: 1)
    if let text = parsed.positional.first {
      guard let value = Double(text), value.isFinite, (0...1).contains(value) else {
        throw UsageError("master volume must be a number from 0 to 1, got '\(text)'")
      }
      await services.system.setMasterVolume(value)
      print("master volume set to \(value)")
    }
    let snapshot = await services.system.currentState()
    guard let master = snapshot.master else {
      print("master: not available for the default output")
      return
    }
    print(
      "master: volume \(String(format: "%.3f", master.volume)), "
        + "\(master.isMuted ? "muted" : "not muted"), default output \(ConsoleText.safe(snapshot.defaultOutputUID))"
    )
  }

  static func probePermission(_ services: Services) async throws {
    let probe = SystemAudioAccessProbe(catalog: services.catalog)
    let verdict = await probe.verify(idleTargetAllowed: true)
    switch verdict {
    case .granted: print("permission: GRANTED (real audio reached the test tap)")
    case .denied:
      print("permission: DENIED (a process was playing but the tap received only zeros)")
      print("  Note: a process that plays pure digital silence looks the same; try music.")
    case .indeterminate:
      print("permission: INDETERMINATE (no process is playing; play something and retry)")
    }
  }
}
