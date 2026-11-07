/// Actions that a global shortcut can trigger.
public enum HotkeyAction: Sendable, Hashable, CaseIterable {
  /// Opens or closes the mixer popover.
  case togglePopover
  /// Mutes or unmutes the frontmost app.
  case toggleFrontmostAppMute
}

/// Global keyboard shortcuts (the `KeyboardShortcuts` package in production).
@MainActor
public protocol HotkeyService {
  /// Calls `handler` whenever the shortcut of `action` is pressed. Replaces a previous handler.
  func setHandler(for action: HotkeyAction, _ handler: @escaping @MainActor () -> Void)
  /// Removes every handler.
  func removeAllHandlers()
}
