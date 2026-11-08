import SwiftUI

/// Wide capsule slider in the style of the Control Center "Sound" module: a rounded track
/// with a light fill up to the value and a speaker symbol inside, at the leading edge. Used by
/// the master volume and by every app. Dragging sets the value directly (the value follows
/// the pointer); arrows and scrolling are handled by the caller (`volumeKeys`, `scrollAdjusts`).
struct CapsuleSlider: View {
  @Binding var value: Double
  let symbol: String
  var symbolIsAlert = false
  var height: CGFloat = 24

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let fillWidth = width * CGFloat(min(max(value, 0), 1))
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.14))
        Rectangle().fill(Color.white).frame(width: fillWidth)
        symbolImage.foregroundStyle(symbolStyle(covered: fillWidth > height * 0.75))
      }
      .clipShape(Capsule())
      .contentShape(Capsule())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          guard width > 0 else { return }
          value = min(max(Double(drag.location.x / width), 0), 1)
        })
    }
    .frame(height: height)
    .accessibilityElement()
  }

  /// Dark on the light fill, secondary on the empty track; red when muted.
  private func symbolStyle(covered: Bool) -> Color {
    if symbolIsAlert { return .red }
    return covered ? Color.black.opacity(0.6) : Color.secondary
  }

  private var symbolImage: some View {
    Image(systemName: symbol)
      .font(.system(size: height * 0.5))
      .frame(width: height, height: height)
  }
}
