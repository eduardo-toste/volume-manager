/// Semantic version `MAJOR.MINOR.PATCH` (SPEC 13.4).
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  /// Major component; incremented for incompatible changes.
  public let major: Int
  /// Minor component; incremented for compatible additions.
  public let minor: Int
  /// Patch component; incremented for fixes.
  public let patch: Int

  /// Creates a version from its three components.
  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Parses `"1.2.3"`. Returns `nil` for anything that is not exactly three
  /// non-negative decimal components.
  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
        let value = Int(part)
      else { return nil }
      numbers.append(value)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
  }

  /// The version as `"MAJOR.MINOR.PATCH"`.
  public var description: String { "\(major).\(minor).\(patch)" }

  /// Orders versions by major, then minor, then patch.
  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
