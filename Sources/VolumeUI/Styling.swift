import AppKit
import SwiftUI

/// Look of the popover, taken from the design (`design/VolumeManager.figcraft`, SPEC 3): a
/// frosted panel with rounded corners, a translucent card for the output and soft highlights.
/// Every view takes its colors from here, so light and dark follow the system appearance and
/// no view checks the macOS version (SPEC 12.6).
enum Palette {
  /// Top and bottom of the panel's tint, laid over the blur of what is behind the window.
  static let panelTop = adaptive(light: NSColor(white: 1, alpha: 0.78), dark: rgb(58, 58, 64, 0.72))
  static let panelBottom = adaptive(
    light: rgb(244, 244, 248, 0.72), dark: rgb(28, 28, 32, 0.78))
  /// Thin light edge of the panel.
  static let panelStroke = adaptive(light: .white.withAlphaComponent(0.8), dark: white(0.18))
  /// The output card.
  static let cardFill = adaptive(light: .white.withAlphaComponent(0.45), dark: white(0.07))
  static let cardStroke = adaptive(light: .white.withAlphaComponent(0.6), dark: white(0.10))
  /// Circle behind the "•••" and mute buttons.
  static let buttonFill = adaptive(light: black(0.059), dark: white(0.10))
  /// A row under the pointer, focused or expanded; the chosen output of an app.
  static let highlight = adaptive(light: black(0.051), dark: white(0.078))
  /// Slider track, and the fill of a muted app.
  static let track = adaptive(light: black(0.10), dark: white(0.14))
  static let mutedFill = adaptive(light: black(0.35), dark: white(0.35))
  /// Slider knob.
  static let knob = adaptive(light: .white, dark: rgb(245, 245, 247, 1))
  static let knobStroke = Color.black.opacity(0.10)
  /// Line above the footer.
  static let separator = adaptive(light: black(0.10), dark: white(0.12))
  /// Mute button of a muted app.
  static let mutedButtonFill = Color(nsColor: .systemRed).opacity(0.15)

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }

  private static func black(_ alpha: CGFloat) -> NSColor { NSColor(white: 0, alpha: alpha) }
  private static func white(_ alpha: CGFloat) -> NSColor { NSColor(white: 1, alpha: alpha) }
  private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat)
    -> NSColor
  {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
  }
}

/// The popover panel: what is behind the window, blurred, under the design's tint, clipped to
/// the panel's rounded shape with a thin light edge. The window is a transparent borderless
/// panel (`MenuBarController`), so nothing square shows around the corners and the window
/// shadow follows the rounded shape. With "Reduce transparency" the system draws the blur
/// opaque.
struct GlassBackground: View {
  static let cornerRadius: CGFloat = 26

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    ZStack {
      BehindWindowBlur(cornerRadius: Self.cornerRadius)
      LinearGradient(
        colors: [Palette.panelTop, Palette.panelBottom], startPoint: .top, endPoint: .bottom)
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(Palette.panelStroke, lineWidth: 1))
  }
}

/// System blur of the windows and desktop behind the popover (`NSVisualEffectView`, available
/// on every supported macOS), limited to a rounded rectangle by its mask image (the documented
/// way to shape it), so no square corner of blur is drawn.
private struct BehindWindowBlur: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .popover
    view.blendingMode = .behindWindow
    view.state = .active
    view.maskImage = Self.roundedMask(radius: cornerRadius)
    return view
  }

  /// A stretchable rounded rectangle: the corners keep their radius at any size.
  private static func roundedMask(radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Rounded translucent card (the "Saída" card of the design).
struct CardBackground: ViewModifier {
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    content
      .background(Palette.cardFill, in: shape)
      .overlay(shape.strokeBorder(Palette.cardStroke, lineWidth: 1))
  }
}

/// Soft highlight of a row or menu item under the pointer, focused or expanded.
struct RowHighlight: ViewModifier {
  let isActive: Bool
  var cornerRadius: CGFloat = 12

  func body(content: Content) -> some View {
    content.background(
      isActive ? Palette.highlight : Color.clear,
      in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

extension View {
  func rowHighlight(isActive: Bool, cornerRadius: CGFloat = 12) -> some View {
    modifier(RowHighlight(isActive: isActive, cornerRadius: cornerRadius))
  }

  func cardBackground() -> some View { modifier(CardBackground()) }
}
