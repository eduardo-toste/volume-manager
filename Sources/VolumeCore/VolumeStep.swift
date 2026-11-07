/// Amount by which keys and scrolling change a slider (SPEC 3.3).
public enum VolumeStep: Int, Sendable, Hashable, CaseIterable {
  /// 1%.
  case one = 1
  /// 5% (default).
  case five = 5
  /// 10%.
  case ten = 10

  /// The step as a fraction of the slider range.
  public var fraction: Double { Double(rawValue) / 100 }
}
