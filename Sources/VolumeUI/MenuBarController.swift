import AppKit
import Observation
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
    updateIcon()
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
    context.store.refreshAudioSystem()
    let permission = context.permission
    Task { await permission.refresh(onlyIfDenied: true) }
  }

  private func didClose() {
    lastClose = ProcessInfo.processInfo.systemUptime
    statusItem.button?.highlight(false)
  }

  /// Shows the icon for the current volume and setting, and again whenever they change.
  private func updateIcon() {
    let settings = context.settings
    let store = context.store
    let name = withObservationTracking {
      settings.menuBarIconStyle.symbolName(volume: store.masterVolume, muted: store.masterMuted)
    } onChange: { [weak self] in
      Task { @MainActor in self?.updateIcon() }
    }
    let image = NSImage(
      systemSymbolName: name,
      accessibilityDescription: String(localized: "popover.title", bundle: .main))
    image?.isTemplate = true
    statusItem.button?.image = image
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
