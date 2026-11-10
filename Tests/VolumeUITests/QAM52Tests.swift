import AppKit
import SwiftUI
import Testing

@testable import VolumeUI

@Suite("QA M5.2: footer and height")
@MainActor
struct QAM52Tests {
  /// With 40 apps the popover is as tall as it ever gets. Whatever the screen, that stays at
  /// about 70% of it (SPEC 3.2), except where the 120 pt floor of the list wins on tiny screens.
  @Test func tallestPopoverStaysWithinSeventyPercentOfAnyScreen() async {
    let scene = await Fixture(apps: (0..<40).map { "App\($0)" })
    let host = NSHostingView(rootView: MenuBarPopover(context: scene.context))
    let actualCeiling = MenuBarPopover.maxListHeight(
      screenHeight: NSScreen.main?.visibleFrame.height ?? 900)
    let tallest = host.fittingSize.height
    let rest = tallest - actualCeiling
    for screen in [CGFloat(800), 900, 1000, 1200, 1440, 2000] {
      let list = MenuBarPopover.maxListHeight(screenHeight: screen)
      let total = rest + list
      #expect(
        total <= screen * 0.7 + 4 || list == 120, "screen \(screen): popover \(total)")
    }
  }

  @Test func floorKeepsTheListUsableOnTinyScreens() {
    #expect(MenuBarPopover.maxListHeight(screenHeight: 300) == 120)
    #expect(MenuBarPopover.maxListHeight(screenHeight: 5000) == 400)
  }
}
