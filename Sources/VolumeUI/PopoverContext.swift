import AppKit
import VolumeCore

/// Everything the popover needs, injected by the composition root: the domain objects it reads
/// and the intents that live outside the domain. The views never talk to services directly.
@MainActor
public struct PopoverContext {
  let store: MixerStore
  let settings: SettingsModel
  let permission: PermissionMonitor
  let icon: @MainActor (String) -> NSImage?
  let openSoundSettings: @MainActor () -> Void
  let showAbout: @MainActor () -> Void
  let quit: @MainActor () -> Void

  /// Creates the context. `icon` returns the cached icon of the app with a bundle ID.
  public init(
    store: MixerStore, settings: SettingsModel, permission: PermissionMonitor,
    icon: @escaping @MainActor (String) -> NSImage?,
    openSoundSettings: @escaping @MainActor () -> Void,
    showAbout: @escaping @MainActor () -> Void,
    quit: @escaping @MainActor () -> Void
  ) {
    self.store = store
    self.settings = settings
    self.permission = permission
    self.icon = icon
    self.openSoundSettings = openSoundSettings
    self.showAbout = showAbout
    self.quit = quit
  }
}
