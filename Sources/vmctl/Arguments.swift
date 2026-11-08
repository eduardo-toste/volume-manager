import Foundation

/// A command line problem; printed as `vmctl: <message>` with exit status 2.
struct UsageError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// A real problem found while running (not a usage mistake); exit status 3.
struct ProblemError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Parsed arguments of one command: positional words, `--name value` options, `--flag` flags.
/// Anything not declared is an error (no silent defaults, M0.5 recommendation 12).
struct Arguments {
  private(set) var positional: [String] = []
  private var values: [String: String] = [:]
  private var flags: Set<String> = []

  init(_ raw: [String], options: Set<String> = [], flags allowedFlags: Set<String> = []) throws {
    var index = 0
    while index < raw.count {
      let word = raw[index]
      index += 1
      guard word.hasPrefix("--") else {
        positional.append(word)
        continue
      }
      let name = String(word.dropFirst(2))
      if allowedFlags.contains(name) {
        flags.insert(name)
      } else if options.contains(name) {
        guard index < raw.count, !raw[index].hasPrefix("--") else {
          throw UsageError("--\(name) needs a value")
        }
        guard values[name] == nil else { throw UsageError("--\(name) given twice") }
        values[name] = raw[index]
        index += 1
      } else {
        throw UsageError("unknown option --\(name)")
      }
    }
  }

  func flag(_ name: String) -> Bool { flags.contains(name) }
  func value(_ name: String) -> String? { values[name] }

  /// A finite number in `range`, or `fallback` when the option is absent. Present but
  /// invalid is an error.
  func number(_ name: String, in range: ClosedRange<Double>, default fallback: Double?) throws
    -> Double?
  {
    guard let text = values[name] else { return fallback }
    guard let number = Double(text), number.isFinite, range.contains(number) else {
      throw UsageError(
        "--\(name) must be a number from \(range.lowerBound) to \(range.upperBound), got '\(text)'"
      )
    }
    return number
  }

  /// Rejects positional arguments beyond `count`.
  func requirePositional(atMost count: Int) throws {
    guard positional.count <= count else {
      throw UsageError("unexpected argument '\(positional[count])'")
    }
  }
}
