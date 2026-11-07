import SwiftUI
import VolumeUI

/// Composition root: the only place that knows every module.
@main
struct VolumeManagerApp: App {
  var body: some Scene {
    MenuBarExtra {
      MenuBarPopover()
    } label: {
      Image(systemName: "speaker.wave.2.fill")
        .accessibilityLabel(Text("popover.title", bundle: .main))
    }
    .menuBarExtraStyle(.window)
  }
}
