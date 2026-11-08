import SwiftUI
import VolumeCore

/// The menu bar item (SPEC 3.1): a speaker that follows the system volume, or the fixed
/// "controls" icon, depending on the setting.
public struct MenuBarIcon: View {
  private let store: MixerStore
  private let settings: SettingsModel

  /// Creates the icon.
  public init(store: MixerStore, settings: SettingsModel) {
    self.store = store
    self.settings = settings
  }

  /// The icon.
  public var body: some View {
    Image(
      systemName: settings.menuBarIconStyle.symbolName(
        volume: store.masterVolume, muted: store.masterMuted)
    )
    .accessibilityLabel(Text("popover.title", bundle: .main))
  }
}
