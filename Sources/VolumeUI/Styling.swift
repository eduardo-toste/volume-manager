import SwiftUI

/// Look of the popover. The window of `MenuBarExtra` already provides the system background
/// (Liquid Glass on macOS 26, a translucent material before) with its rounded corners, so the
/// content paints no background of its own: a rectangle on top would square the corners and
/// hide the translucency. With "Reduce transparency" the system makes the window opaque.

/// Soft highlight of a row or menu item under the pointer or with keyboard focus.
struct RowHighlight: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    content.background(
      isActive ? Color.primary.opacity(0.08) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension View {
  func rowHighlight(isActive: Bool) -> some View { modifier(RowHighlight(isActive: isActive)) }
}
