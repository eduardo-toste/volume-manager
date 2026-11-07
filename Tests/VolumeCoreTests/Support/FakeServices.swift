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
  }

  struct Failure: Error {}

  private let state = Mutex(State())
  var openedSettingsCount: Int { state.withLock { $0.openedSettings } }

  func status() -> LoginItemStatus { state.withLock { $0.status } }

  func setEnabled(_ enabled: Bool) throws {
    state.withLock { $0.status = enabled ? .enabled : .disabled }
  }

  func openLoginItemsSettings() { state.withLock { $0.openedSettings += 1 } }
}

/// Permission double.
final class FakePermissionService: PermissionService, Sendable {
  private let granted = Mutex(AudioPermissionStatus.notDetermined)

  func currentStatus() async -> AudioPermissionStatus { granted.withLock { $0 } }

  func request() async -> AudioPermissionStatus {
    granted.withLock { $0 = .granted }
    return .granted
  }

  func openPrivacySettings() {}
}

/// Hotkey double: tests press the shortcut with `press(_:)`.
@MainActor
final class FakeHotkeyService: HotkeyService {
  private var handlers: [HotkeyAction: @MainActor () -> Void] = [:]

  func setHandler(for action: HotkeyAction, _ handler: @escaping @MainActor () -> Void) {
    handlers[action] = handler
  }

  func removeAllHandlers() { handlers = [:] }

  func press(_ action: HotkeyAction) { handlers[action]?() }

  var handlerCount: Int { handlers.count }
}
