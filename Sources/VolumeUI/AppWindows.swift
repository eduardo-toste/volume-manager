import AppKit
import SwiftUI
import VolumeCore

/// The settings window (one instance) and the welcome window. Both are plain `NSWindow`s, so
/// they can be brought to the front from the popover panel and from the app delegate, which a
/// SwiftUI scene cannot do for an app without a Dock icon.
@MainActor
public final class AppWindows {
  private let settingsContext: SettingsContext
  private var settingsWindow: NSWindow?
  private var welcomeWindow: NSWindow?

  /// Creates the controller. No window exists until it is first shown.
  public init(settings: SettingsContext) {
    settingsContext = settings
  }

  /// Shows the settings window, creating it on first use, in front and with the keyboard focus.
  public func showSettings() {
    let window = settingsWindow ?? makeSettingsWindow()
    settingsWindow = window
    bringToFront(window)
  }

  /// Shows the welcome window. `onStart` runs after "Começar", once the window is closed.
  public func showWelcome(model: WelcomeModel, onStart: @escaping @MainActor () -> Void) {
    if let welcomeWindow {
      bringToFront(welcomeWindow)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(
      rootView: WelcomeView(
        model: model,
        onStart: { [weak self] in
          self?.welcomeWindow?.close()
          self?.welcomeWindow = nil
          onStart()
        }))
    welcomeWindow = window
    bringToFront(window)
  }

  private func makeSettingsWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(
      rootView: SettingsView(context: settingsContext))
    return window
  }

  /// The app has no Dock icon, so it must come to the front for the window to be seen.
  private func bringToFront(_ window: NSWindow) {
    if !window.isVisible { window.center() }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
}
