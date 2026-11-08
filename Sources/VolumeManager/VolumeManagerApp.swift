import AppKit
import SwiftUI
import VolumeUI

/// The app: a menu bar item with the mixer popover. Everything is built by `Composition`.
@main
struct VolumeManagerApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarPopover(context: delegate.composition.context)
    } label: {
      MenuBarIcon(store: delegate.composition.store, settings: delegate.composition.settings)
    }
    .menuBarExtraStyle(.window)

    // Placeholder until the settings window (M5).
    Settings {
      Text("settings.placeholder", bundle: .main)
        .padding(32)
    }
  }
}

/// Owns the composition and starts it when the app finishes launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let composition = Composition()

  func applicationDidFinishLaunching(_ notification: Notification) {
    composition.start()
  }
}
