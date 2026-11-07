import AppKit
import Foundation

/// Calls `onCleanExit` when the user's session ends normally (power off, restart, log out) or
/// the app terminates normally, so the domain can call `SafetyPolicy.markCleanExit()`.
/// Wiring only; the composition root connects it (M4/M6).
@MainActor
public final class SessionLifecycleObserver {
  private let onCleanExit: @MainActor () -> Void
  private var tokens: [any NSObjectProtocol] = []
  private var centers: [NotificationCenter] = []

  /// Starts observing. Defaults are the real workspace and default notification centers.
  public init(
    workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    appCenter: NotificationCenter = .default,
    onCleanExit: @escaping @MainActor () -> Void
  ) {
    self.onCleanExit = onCleanExit
    observe(NSWorkspace.willPowerOffNotification, on: workspaceCenter)
    observe(NSApplication.willTerminateNotification, on: appCenter)
  }

  isolated deinit {
    stop()
  }

  /// Stops observing. Safe to call more than once.
  public func stop() {
    for (center, token) in zip(centers, tokens) { center.removeObserver(token) }
    centers.removeAll()
    tokens.removeAll()
  }

  private func observe(_ name: Notification.Name, on center: NotificationCenter) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.onCleanExit() }
    }
    centers.append(center)
    tokens.append(token)
  }
}
