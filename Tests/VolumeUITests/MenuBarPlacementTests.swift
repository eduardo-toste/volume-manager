import AppKit
import Testing

@testable import VolumeUI

/// Where the popover panel opens (SPEC 3.1): under the icon, just below the menu bar, inside
/// the screen. Pure geometry, plus the panel keeping its top when the content changes size.
@MainActor
@Suite("Menu bar panel placement")
struct MenuBarPlacementTests {
  private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
  private let size = CGSize(width: 320, height: 500)

  private func button(midX: CGFloat) -> CGRect {
    CGRect(x: midX - 16, y: 944, width: 32, height: 24)
  }

  @Test func opensCenteredUnderTheIconJustBelowTheMenuBar() {
    let frame = MenuBarController.panelFrame(
      size: size, buttonFrame: button(midX: 900), visibleFrame: screen)
    #expect(frame.midX == 900)
    #expect(frame.maxY == 944 - MenuBarController.gap)
    #expect(frame.size == size)
  }

  @Test func staysInsideTheScreenNearTheRightEdge() {
    let frame = MenuBarController.panelFrame(
      size: size, buttonFrame: button(midX: 1500), visibleFrame: screen)
    #expect(frame.maxX == 1512 - MenuBarController.screenMargin)
  }

  @Test func staysInsideTheScreenNearTheLeftEdge() {
    let frame = MenuBarController.panelFrame(
      size: size, buttonFrame: button(midX: 20), visibleFrame: screen)
    #expect(frame.minX == MenuBarController.screenMargin)
  }

  @Test func followsTheScreenOfTheIcon() {
    let second = CGRect(x: 1512, y: 0, width: 1920, height: 1055)
    let icon = CGRect(x: 3000, y: 1055, width: 32, height: 24)
    let frame = MenuBarController.panelFrame(size: size, buttonFrame: icon, visibleFrame: second)
    #expect(second.contains(frame))
  }

  @Test func usesWholePointsSoTheEdgesStaySharp() {
    let frame = MenuBarController.panelFrame(
      size: size, buttonFrame: CGRect(x: 900.3, y: 944, width: 31.5, height: 24),
      visibleFrame: screen)
    #expect(frame.origin.x == frame.origin.x.rounded())
    #expect(frame.origin.y == frame.origin.y.rounded())
  }

  @Test func panelIsTransparentAndKeepsItsTopWhenTheContentGrows() {
    let panel = PopoverPanel()
    #expect(!panel.isOpaque)
    #expect(panel.backgroundColor == .clear)
    #expect(panel.hasShadow)
    #expect(panel.canBecomeKey)
    panel.setFrame(CGRect(x: 100, y: 400, width: 320, height: 300), display: false)
    panel.keepTopAndResize(to: CGSize(width: 320, height: 360))
    #expect(panel.frame.maxY == 700)
    #expect(panel.frame.height == 360)
    panel.keepTopAndResize(to: CGSize(width: 320, height: 250))
    #expect(panel.frame.maxY == 700)
  }

  @Test func closingReportsOnlyWhenItWasOpen() {
    let panel = PopoverPanel()
    var closes = 0
    panel.onClose = { closes += 1 }
    panel.close()
    #expect(closes == 0)
  }
}
