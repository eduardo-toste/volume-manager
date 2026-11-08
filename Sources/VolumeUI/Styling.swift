import SwiftUI

/// Look of the popover. This file is the only place with `#available`: on macOS 26 and later
/// it uses Liquid Glass, before that the native translucent materials (SPEC 12.6). With
/// "Reduce transparency" the system makes both opaque by itself.

/// Background of the whole popover.
struct GlassBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.regular, in: .rect)
    } else {
      content.background(.regularMaterial)
    }
  }
}

/// Background of a card ("Saída principal").
struct CardBackground: ViewModifier {
  private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content.background(.thinMaterial, in: shape)
    }
  }
}

/// Soft highlight of a row or menu item under the pointer.
struct RowHighlight: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    content.background(
      isActive ? Color.primary.opacity(0.08) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension View {
  func glassBackground() -> some View { modifier(GlassBackground()) }
  func cardBackground() -> some View { modifier(CardBackground()) }
  func rowHighlight(isActive: Bool) -> some View { modifier(RowHighlight(isActive: isActive)) }
}
