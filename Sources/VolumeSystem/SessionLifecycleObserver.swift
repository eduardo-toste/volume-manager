import AppKit
import Foundation

/// Calls `onCleanExit` when the user's session ends normally (power off, restart, log out) or
/// the app terminates normally, so the domain can call `SafetyPolicy.markCleanExit()`; and
/// `onResume` when the Mac wakes up or this user's session becomes active again (fast user
/// switching), so the taps can be rebuilt (SPEC 8). Wiring only; the composition root connects it.
@MainActor
public final class SessionLifecycleObserver {
  private var tokens: [any NSObjectProtocol] = []
  private var centers: [NotificationCenter] = []

  /// Starts observing. Defaults are the real workspace and default notification centers.
  public init(
    workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    appCenter: NotificationCenter = .default,
    onCleanExit: @escaping @MainActor () -> Void,
    onResume: @escaping @MainActor () -> Void
  ) {
    observe(NSWorkspace.willPowerOffNotification, on: workspaceCenter, onCleanExit)
    observe(NSApplication.willTerminateNotification, on: appCenter, onCleanExit)
    observe(NSWorkspace.didWakeNotification, on: workspaceCenter, onResume)
    observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspaceCenter, onResume)
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

  private func observe(
    _ name: Notification.Name, on center: NotificationCenter,
    _ action: @escaping @MainActor () -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { action() }
    }
    centers.append(center)
    tokens.append(token)
  }
}
