import AppKit
import VolumeUI

/// Owns the composition and the menu bar item, and starts them when the app finishes launching.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let composition = Composition()
  private var menuBar: MenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    composition.start()
    let menuBar = MenuBarController(context: composition.context)
    self.menuBar = menuBar
    installMainMenu()
    composition.showWelcomeIfNeeded { [weak menuBar] in menuBar?.showPopover() }
  }

  /// Opening the app again while it runs (double click in the Finder) opens the settings
  /// (SPEC 8).
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    composition.windows.showSettings()
    return false
  }

  /// The menu bar of an app without a Dock icon is never shown, but its key equivalents work
  /// whenever one of the app's windows has the focus: ⌘, opens the settings, ⌘W closes the
  /// window and ⌘Q quits through the same path as the popover (taps destroyed first).
  private func installMainMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      menuItem("menu.settings", #selector(openSettings), key: ","))
    appMenu.addItem(.separator())
    appMenu.addItem(menuItem("menu.close", #selector(NSWindow.performClose(_:)), key: "w"))
    appMenu.addItem(menuItem("menu.quit", #selector(quit), key: "q"))
    appItem.submenu = appMenu
    NSApp.mainMenu = menu
  }

  private func menuItem(_ title: String.LocalizationValue, _ action: Selector, key: String)
    -> NSMenuItem
  {
    let item = NSMenuItem(
      title: String(localized: title, bundle: .main), action: action, keyEquivalent: key)
    item.target = action == #selector(NSWindow.performClose(_:)) ? nil : self
    return item
  }

  @objc private func openSettings() { composition.windows.showSettings() }

  @objc private func quit() { composition.quit() }
}
