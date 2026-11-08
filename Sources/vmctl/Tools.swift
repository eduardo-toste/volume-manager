import CoreAudio
import Darwin
import Foundation
import Synchronization
import VolumeAudio
import VolumeCore
import VolumeSystem

/// Everything the commands share: real services wired the way the app will wire them.
struct Services {
  let provider = WorkspaceAppInfoProvider()
  let catalog: ProcessCatalog
  let system: CoreAudioSystem

  init() {
    let provider = provider
    catalog = ProcessCatalog(
      info: provider, responsiblePID: { provider.responsiblePID(forPID: $0) })
    system = CoreAudioSystem(catalog: catalog)
  }

  /// Apps as the mixer groups them (without vmctl itself).
  func groups(_ processes: [AudioProcessInfo]) -> [AudioApp] {
    ProcessGrouping.group(processes, info: provider, excludedPID: getpid())
  }
}

/// Collects failures reported by the controller.
final class FailureLog: Sendable {
  private let items = Mutex<[AppAudioFailure]>([])
  func add(_ failure: AppAudioFailure) { items.withLock { $0.append(failure) } }
  var all: [AppAudioFailure] { items.withLock { $0 } }
}

/// Identity check for a single `pid:N` target (tools such as `afplay` have no bundle): the PID
/// must still run the same executable.
struct PinnedPIDIdentity: ProcessIdentityChecking {
  let pid: Int32
  let path: String?
  let catalog: ProcessCatalog
  let provider: WorkspaceAppInfoProvider

  func confirm(pid candidate: Int32, belongsTo app: ControlledApp) -> Bool {
    guard candidate == pid, app.id == "pid:\(pid)", catalog.processInfo(pid: pid) != nil,
      let path
    else { return false }
    return provider.executablePath(forPID: pid) == path
  }
}

/// The app a command acts on, with the identity check that goes with it.
struct Target {
  let app: ControlledApp
  let identity: any ProcessIdentityChecking
  let label: String
}

extension Services {
  /// Resolves `<bundleID>` or `pid:<N>`.
  func resolveTarget(_ text: String) throws -> Target {
    let processes = catalog.processes()
    if text.hasPrefix("pid:") {
      guard let pid = Int32(text.dropFirst(4)), pid > 0 else {
        throw UsageError("invalid pid in '\(text)'")
      }
      guard processes.contains(where: { $0.pid == pid }) else {
        throw UsageError("process \(pid) is not an audio process right now")
      }
      let path = provider.executablePath(forPID: pid)
      return Target(
        app: ControlledApp(id: "pid:\(pid)", bundleID: nil, pids: [pid]),
        identity: PinnedPIDIdentity(pid: pid, path: path, catalog: catalog, provider: provider),
        label: "pid \(pid)")
    }
    guard
      let app = groups(processes).first(where: {
        $0.bundleID?.caseInsensitiveCompare(text) == .orderedSame || $0.id == text
      })
    else { throw UsageError("no audio app matches '\(text)' (see: vmctl processes)") }
    return Target(
      app: ControlledApp(app),
      identity: GroupedProcessIdentity(catalog: catalog, info: provider),
      label: ConsoleText.safe(app.name))
  }
}

/// CPU time used by this process so far, in seconds.
func cpuSeconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
  return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func printError(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}
