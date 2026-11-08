import AppKit
import SwiftUI
import VolumeCore

/// Keyboard and scroll input for a volume control (SPEC 6): the arrows and the scroll wheel
/// move the value by the volume step; the closure receives the signed number of steps.
extension View {
  /// Makes the view a keyboard focus target without the system focus ring (callers show their
  /// own soft highlight). Arrows adjust the volume, Space (when given) toggles mute.
  func volumeKeys(adjust: @escaping @MainActor (Int) -> Void, space: (@MainActor () -> Void)? = nil)
    -> some View
  {
    focusable()
      .focusEffectDisabled()
      .onKeyPress(keys: [.leftArrow, .downArrow, .rightArrow, .upArrow]) { press in
        adjust(press.key == .leftArrow || press.key == .downArrow ? -1 : 1)
        return .handled
      }
      .onKeyPress(.space) {
        guard let space else { return .ignored }
        space()
        return .handled
      }
  }

  /// Scrolling with the pointer over this view adjusts the volume instead of scrolling the list.
  func scrollAdjusts(_ adjust: @escaping @MainActor (Int) -> Void) -> some View {
    background(ScrollCatcher(adjust: adjust))
  }
}

/// Invisible view that catches scroll-wheel events over its own bounds. It never receives
/// clicks, so the slider on top of it works as usual.
private struct ScrollCatcher: NSViewRepresentable {
  let adjust: @MainActor (Int) -> Void

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.adjust = adjust
    return view
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.adjust = adjust
  }
}

private final class CatcherView: NSView {
  /// Trackpad movement (points) that counts as one step.
  private static let pointsPerStep: CGFloat = 12

  var adjust: (@MainActor (Int) -> Void)?
  private var monitor: Any?
  private var accumulated: CGFloat = 0

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeMonitor()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
      return consumed ? nil : event
    }
  }

  isolated deinit {
    removeMonitor()
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  /// Returns true when the event was over this view and was used.
  private func handle(_ event: NSEvent) -> Bool {
    guard event.window === window,
      bounds.contains(convert(event.locationInWindow, from: nil))
    else { return false }
    let delta = event.scrollingDeltaY
    guard delta != 0 else { return true }
    if event.hasPreciseScrollingDeltas {
      accumulated += delta
      let steps = Int(accumulated / Self.pointsPerStep)
      guard steps != 0 else { return true }
      accumulated -= CGFloat(steps) * Self.pointsPerStep
      adjust?(steps)
    } else {
      adjust?(delta > 0 ? 1 : -1)
    }
    return true
  }
}
