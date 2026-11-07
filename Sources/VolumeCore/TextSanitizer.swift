/// Cleans text that comes from other processes or devices (names, bundle IDs, paths).
///
/// The result is plain text that is safe to show: it never contains control characters, bidi
/// overrides or invisible characters, and it is never interpreted (SPEC 12.9.4).
public enum TextSanitizer {
  /// Maximum number of characters kept by default.
  public static let maxLength = 200

  /// Most scalars ever inspected, so a hostile multi-megabyte string costs bounded work.
  private static let maxScan = 4096

  /// Removes control and format characters (C0/C1, bidi overrides and isolates, zero-width and
  /// invisible characters, soft hyphen, tags, byte order mark), turns every kind of whitespace
  /// into one space, trims, and truncates to `limit` characters (and a bounded number of UTF-8
  /// bytes). The zero-width joiner and non-joiner are kept only between two visible characters
  /// (emoji sequences, Persian and Indic text), one at a time.
  public static func clean(_ input: String, limit: Int = maxLength) -> String {
    guard limit > 0 else { return "" }
    var output = String.UnicodeScalarView()
    var pendingSpace = false
    var pendingJoiner: Unicode.Scalar?
    var lastIsVisible = false
    for scalar in input.unicodeScalars.prefix(maxScan) {
      if isWhitespace(scalar) {
        pendingSpace = !output.isEmpty
        pendingJoiner = nil
        lastIsVisible = false
        continue
      }
      if isJoiner(scalar) {
        if lastIsVisible, pendingJoiner == nil { pendingJoiner = scalar }
        continue
      }
      if isRemoved(scalar) { continue }
      if pendingSpace {
        output.append(" ")
        pendingSpace = false
      }
      if let joiner = pendingJoiner {
        output.append(joiner)
        pendingJoiner = nil
      }
      output.append(scalar)
      lastIsVisible = true
    }
    var text = String(output)
    if text.count > limit { text = String(text.prefix(limit)) }
    while text.utf8.count > limit * 4 { text.removeLast() }
    while let last = text.unicodeScalars.last, isJoiner(last) { text.unicodeScalars.removeLast() }
    return text
  }

  private static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value == 0x200C || scalar.value == 0x200D
  }

  /// Whitespace of any kind, including tab, newline, no-break space and line separators.
  private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
    default: return scalar == "\t" || scalar == "\n" || scalar == "\r"
    }
  }

  /// Characters that are dropped: every control (Cc) and format (Cf) character, which covers
  /// bidi controls, zero-width characters, invisible operators, tags and the byte order mark,
  /// plus a few invisible characters the Unicode category does not cover.
  private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format: return true
    default: break
    }
    switch scalar.value {
    case 0x180E, 0x061C, 0x2060, 0xFEFF, 0xFFF9...0xFFFB: return true
    case 0xE0000...0xE007F: return true
    default: return false
    }
  }
}
