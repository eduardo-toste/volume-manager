import Synchronization

@testable import VolumeCore

/// Answers app lookups from dictionaries the test fills in.
final class FakeAppInfoProvider: AppInfoProvider, Sendable {
  private struct Tables {
    var paths: [Int32: String] = [:]
    var names: [String: String] = [:]
    var bundleIDs: [String: String] = [:]
  }

  private let tables = Mutex(Tables())

  func setPath(_ path: String, forPID pid: Int32) { tables.withLock { $0.paths[pid] = path } }
  func setApp(_ path: String, name: String?, bundleID: String?) {
    tables.withLock {
      $0.names[path] = name
      $0.bundleIDs[path] = bundleID
    }
  }

  func executablePath(forPID pid: Int32) -> String? { tables.withLock { $0.paths[pid] } }
  func appName(atAppPath appPath: String) -> String? { tables.withLock { $0.names[appPath] } }
  func bundleID(atAppPath appPath: String) -> String? { tables.withLock { $0.bundleIDs[appPath] } }
}

/// Login item double.
final class FakeLoginItemService: LoginItemService, Sendable {
  private struct State {
    var status = LoginItemStatus.disabled
    var openedSettings = 0
    var changes: [Bool] = []
    var failing = false
  }

  struct Failure: Error {}

  private let state = Mutex(State())
  var openedSettingsCount: Int { state.withLock { $0.openedSettings } }
  /// Registrations asked for, in order (`true` register, `false` unregister).
  var changes: [Bool] { state.withLock { $0.changes } }

  /// What the system reports from now on (the user changed it in System Settings).
  func setStatus(_ status: LoginItemStatus) { state.withLock { $0.status = status } }
  /// Makes the next changes fail, as when the system refuses.
  func failChanges(_ fail: Bool) { state.withLock { $0.failing = fail } }

  func status() -> LoginItemStatus { state.withLock { $0.status } }

  func setEnabled(_ enabled: Bool) throws {
    try state.withLock {
      if $0.failing { throw Failure() }
      $0.changes.append(enabled)
      $0.status = enabled ? .enabled : .disabled
    }
  }

  func openLoginItemsSettings() { state.withLock { $0.openedSettings += 1 } }
}

/// Permission double.
final class FakePermissionService: PermissionService, Sendable {
  private let granted = Mutex(AudioPermissionStatus.notDetermined)

  func request() async -> AudioPermissionStatus {
    granted.withLock { $0 = .granted }
    return .granted
  }

  func openPrivacySettings() {}
}

/// Permission double whose answer the test chooses.
final class ScriptedPermissionService: PermissionService, Sendable {
  private let state = Mutex(
    (answer: AudioPermissionStatus.notDetermined, requests: 0, opened: 0, conclusive: true))

  var answer: AudioPermissionStatus {
    get { state.withLock { $0.answer } }
    set { state.withLock { $0.answer = newValue } }
  }
  var requests: Int { state.withLock { $0.requests } }
  /// False makes the checks inconclusive (nothing was playing): `request()` answers
  /// `.notDetermined`.
  var conclusive: Bool {
    get { state.withLock { $0.conclusive } }
    set { state.withLock { $0.conclusive = newValue } }
  }
  var opened: Int { state.withLock { $0.opened } }

  func request() async -> AudioPermissionStatus {
    state.withLock {
      $0.requests += 1
      return $0.conclusive ? $0.answer : .notDetermined
    }
  }

  func openPrivacySettings() { state.withLock { $0.opened += 1 } }
}

/// A monitor that already knows the permission was confirmed, for tests that are not about it.
@MainActor
func grantedPermission() -> PermissionMonitor {
  PermissionMonitor(service: ScriptedPermissionService(), status: .granted)
}
