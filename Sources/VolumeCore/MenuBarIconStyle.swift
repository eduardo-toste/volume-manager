/// Style of the menu bar icon (SPEC 3.1 and 3.3).
public enum MenuBarIconStyle: String, Sendable, Hashable, CaseIterable {
  /// Speaker that reflects the system volume.
  case speaker
  /// Fixed sliders icon.
  case controls

  /// SF Symbol for the icon, given the system volume and mute state.
  public func symbolName(volume: Double, muted: Bool) -> String {
    switch self {
    case .controls:
      return "slider.horizontal.3"
    case .speaker:
      let level = VolumeCurve.clampedVolume(volume)
      if muted || level <= 0 { return "speaker.slash.fill" }
      if level <= 0.33 { return "speaker.wave.1.fill" }
      if level <= 0.66 { return "speaker.wave.2.fill" }
      return "speaker.wave.3.fill"
    }
  }
}
