import AppKit
import SwiftUI
import VolumeCore

/// The menu bar item and its popover (SPEC 3.1): an `NSStatusItem` whose icon follows the
/// volume, and a borderless transparent panel under it that hosts `MenuBarPopover`. The panel
/// draws nothing of its own, so only the design's rounded translucent background is seen.
///
/// The panel closes when it stops being the key window (a click anywhere else), with Esc, or
/// with another click on the icon. No global event monitor is used.
@MainActor
public final class MenuBarController: NSObject {
  /// Space between the bottom of the menu bar and the top of the panel.
  static let gap: CGFloat = 4
  /// Closest the panel gets to the sides of the screen.
  static let screenMargin: CGFloat = 8
  /// A click on the icon that closed the panel (it took the focus away) must not reopen it.
  private static let reopenDelay: TimeInterval = 0.25

  private let context: PopoverContext
  private let statusItem: NSStatusItem
  private let panel = PopoverPanel()
  private var lastClose: TimeInterval = 0

  /// Creates the menu bar item. The popover is built once and kept, so it opens at once.
  public init(context: PopoverContext) {
    self.context = context
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    let panel = panel
    let content = MenuBarPopover(context: context)
      .fixedSize()
      .onGeometryChange(
        for: CGSize.self, of: { $0.size },
        action: { [weak panel] size in panel?.keepTopAndResize(to: size) })
    panel.contentView = NSHostingView(rootView: content)
    panel.onClose = { [weak self] in self?.didClose() }
    statusItem.button?.target = self
    statusItem.button?.action = #selector(toggle)
    statusItem.button?.image = Self.makeIcon()
  }

  /// Where the panel goes: centered under the icon, just below the menu bar, inside the
  /// visible part of the screen. Everything in screen coordinates.
  static func panelFrame(size: CGSize, buttonFrame: CGRect, visibleFrame: CGRect) -> CGRect {
    let centered = buttonFrame.midX - size.width / 2
    let lowest = visibleFrame.minX + screenMargin
    let highest = visibleFrame.maxX - screenMargin - size.width
    let x = max(lowest, min(centered, highest))
    let top = min(buttonFrame.minY, visibleFrame.maxY) - gap
    return CGRect(
      x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
  }

  @objc private func toggle() {
    if panel.isVisible {
      panel.close()
    } else if ProcessInfo.processInfo.systemUptime - lastClose > Self.reopenDelay {
      show()
    }
  }

  /// Opens the popover (once, after the welcome window, to show where the app lives).
  public func showPopover() {
    if !panel.isVisible { show() }
  }

  /// Sizes and places the panel before it appears, so it never moves on its own.
  private func show() {
    guard let button = statusItem.button, let buttonWindow = button.window,
      let contentView = panel.contentView
    else { return }
    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = buttonWindow.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? buttonFrame
    let frame = Self.panelFrame(
      size: contentView.fittingSize, buttonFrame: buttonFrame, visibleFrame: visible)
    panel.setFrame(frame, display: true)
    panel.makeKeyAndOrderFront(nil)
    panel.invalidateShadow()
    button.highlight(true)
    context.store.popoverOpened()
  }

  private func didClose() {
    lastClose = ProcessInfo.processInfo.systemUptime
    statusItem.button?.highlight(false)
  }

  /// The "three faders" glyph of the design, a fixed template image: the system draws it in the
  /// menu bar color and highlights it while the popover is open (18 x 18 pt, origin at the top
  /// left).
  static func makeIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      for x in [4.5, 9, 13.5] {
        let rail = NSBezierPath()
        rail.lineWidth = 1.5
        rail.lineCapStyle = .round
        rail.move(to: NSPoint(x: x, y: 2))
        rail.line(to: NSPoint(x: x, y: 16))
        rail.stroke()
      }
      for (x, y) in [(2.0, 10.0), (6.5, 4.0), (11.0, 8.0)] {
        NSBezierPath(
          roundedRect: NSRect(x: x, y: y, width: 5, height: 3), xRadius: 1.3, yRadius: 1.3
        ).fill()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = AppIdentity.displayName
    return image
  }
}

/// Borderless, transparent panel that can take the keyboard without activating the app or
/// bringing its other windows forward. It closes when it loses the keyboard focus or on Esc.
final class PopoverPanel: NSPanel {
  var onClose: (() -> Void)?

  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .popUpMenu
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    close()
  }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  override func close() {
    let wasVisible = isVisible
    super.close()
    if wasVisible { onClose?() }
  }

  /// The popover changed size (an app appeared, a row expanded): the top stays under the menu
  /// bar and the panel grows or shrinks downward.
  func keepTopAndResize(to size: CGSize) {
    guard size.width > 0, size.height > 0, size != frame.size else { return }
    var next = frame
    next.origin.y = frame.maxY - size.height
    next.size = size
    setFrame(next, display: isVisible)
    invalidateShadow()
  }
}
