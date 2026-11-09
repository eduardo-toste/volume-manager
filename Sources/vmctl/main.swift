import Foundation
import VolumeCore

/// Development-only command line tool. It is never shipped inside Volume Manager.app.
let usage = """
  vmctl \(AppIdentity.displayName) development tool

  Usage:
    vmctl devices
    vmctl processes
    vmctl master [0..1]
    vmctl set <bundleID|pid:N> [--volume 0..1] [--mute] [--device UID] [--duration SECONDS]
    vmctl restore
    vmctl stress-taps <n> --app <bundleID|pid:N> [--device UID]
    vmctl probe-permission

  Without the System Audio Recording permission taps deliver only zeros. Run this tool
  through scripts/make-vmctl-app.sh (a bundle with a usage description) to be asked for it.
  """

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let command = arguments.first else {
    print(usage)
    exit(0)
  }
  let rest = Array(arguments.dropFirst())
  let services = Services()
  switch command {
  case "devices":
    try Arguments(rest).requirePositional(atMost: 0)
    try await ReadCommands.devices(services)
  case "processes":
    try Arguments(rest).requirePositional(atMost: 0)
    try await ReadCommands.processes(services)
  case "master": try await ReadCommands.master(services, arguments: rest)
  case "set": try await TapCommands.set(services, arguments: rest)
  case "restore":
    try Arguments(rest).requirePositional(atMost: 0)
    try await TapCommands.restore()
  case "stress-taps": try await TapCommands.stress(services, arguments: rest)
  case "probe-permission":
    try Arguments(rest).requirePositional(atMost: 0)
    try await ReadCommands.probePermission(services)
  case "help", "--help", "-h": print(usage)
  default: throw UsageError("unknown command '\(command)'\n\n\(usage)")
  }
} catch let error as UsageError {
  printError("vmctl: \(error)")
  exit(2)
} catch let error as ProblemError {
  printError("vmctl: \(error)")
  exit(3)
} catch {
  printError("vmctl: \(error)")
  exit(1)
}
