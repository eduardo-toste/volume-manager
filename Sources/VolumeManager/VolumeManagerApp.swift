import AppKit
import SwiftUI
import VolumeUI

/// The app: a menu bar item with the mixer popover (`MenuBarController`) and the settings
/// window. Everything is built by `Composition`.
@main
struct VolumeManagerApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    // Placeholder until the settings window (M5).
    Settings {
      Text("settings.placeholder", bundle: .main)
        .padding(32)
    }
  }
}

/// Owns the composition and the menu bar item, and starts them when the app finishes launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let composition = Composition()
  private var menuBar: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    composition.start()
    menuBar = MenuBarController(context: composition.context)
  }
}
