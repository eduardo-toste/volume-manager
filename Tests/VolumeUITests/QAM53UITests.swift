import AppKit
import SwiftUI
import Testing
import VolumeCore

@testable import VolumeUI

@Suite("QA M5.3 UI: footer shortcuts", .serialized)
@MainActor
struct QAM53UITests {
  final class Counter {
    var settings = 0
    var quit = 0
  }

  private func hosted(_ counter: Counter) async -> (NSWindow, NSHostingView<MenuBarPopover>) {
    let scene = await Fixture(apps: ["Spotify", "Safari"])
    return build(scene.context, counter)
  }

  private func build(_ c: PopoverContext, _ counter: Counter) -> (
    NSWindow, NSHostingView<MenuBarPopover>
  ) {
    let context = PopoverContext(
      store: c.store, settings: c.settings, permission: c.permission, icon: c.icon,
      openSoundSettings: {}, showSettings: { counter.settings += 1 }, showAbout: {},
      quit: { counter.quit += 1 })
    _ = NSApplication.shared
    let host = NSHostingView(rootView: MenuBarPopover(context: context))
    let size = host.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    return (window, host)
  }

  private func key(_ chars: String, window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: chars,
      charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)
  }

  @Test func commandCommaAndCommandQReachTheirActions() async throws {
    let counter = Counter()
    let (window, host) = await hosted(counter)
    let comma = try #require(key(",", window: window))
    let q = try #require(key("q", window: window))
    _ = host.performKeyEquivalent(with: comma)
    _ = host.performKeyEquivalent(with: q)
    #expect(counter.settings == 1, "cmd-, did not fire")
    #expect(counter.quit == 1, "cmd-q did not fire")
  }
}
