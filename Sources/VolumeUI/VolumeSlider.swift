import SwiftUI

/// The slider of the design: a thin track, an accent fill up to the value and a white pill
/// knob with a soft shadow. Used by the master volume and by every app. Dragging moves the
/// knob with the pointer (clicking the track jumps there). The caller gives the accessibility
/// label, value and adjustable action, and the arrows and scrolling (`volumeKeys`,
/// `scrollAdjusts`), so every input goes through the same volume step.
struct VolumeSlider: View {
  @Binding var value: Double
  /// Gray fill instead of the accent (a muted app keeps its value, SPEC 3.2).
  var isDimmed = false

  private static let height: CGFloat = 19
  private static let trackHeight: CGFloat = 5
  private static let knobSize = CGSize(width: 22, height: 14)

  var body: some View {
    GeometryReader { proxy in
      let travel = max(proxy.size.width - Self.knobSize.width, 1)
      let center = Self.knobSize.width / 2 + travel * CGFloat(min(max(value, 0), 1))
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.track).frame(height: Self.trackHeight)
        Capsule()
          .fill(isDimmed ? Palette.mutedFill : Color.accentColor)
          .frame(width: center, height: Self.trackHeight)
        knob.offset(x: center - Self.knobSize.width / 2)
      }
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          let position = (drag.location.x - Self.knobSize.width / 2) / travel
          value = Double(min(max(position, 0), 1))
        })
    }
    .frame(height: Self.height)
    .accessibilityElement()
  }

  private var knob: some View {
    Capsule()
      .fill(Palette.knob)
      .overlay(Capsule().strokeBorder(Palette.knobStroke, lineWidth: 0.5))
      .frame(width: Self.knobSize.width, height: Self.knobSize.height)
      .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
      .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
  }
}
