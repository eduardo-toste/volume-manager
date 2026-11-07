/// Lexical handling of executable paths reported by other processes. Never touches the file
/// system: the path is untrusted text.
public enum AppPath {
  /// Longest path accepted, in UTF-8 bytes.
  public static let maxLength = 1024

  /// Resolves `.`, `..` and repeated slashes. Returns `nil` for relative paths, paths with
  /// control characters and paths that are too long. `..` never climbs above the root.
  public static func canonicalize(_ path: String) -> String? {
    guard path.hasPrefix("/"), path.utf8.count <= maxLength else { return nil }
    guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      return nil
    }
    var stack: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch part {
      case ".": continue
      case "..": _ = stack.popLast()
      default: stack.append(part)
      }
    }
    return "/" + stack.joined(separator: "/")
  }

  /// Path of the outermost `X.app` that contains the executable (`…/X.app/Contents/…`), after
  /// canonicalization. This resolves Chrome, Edge, Brave and Electron helpers to the main app.
  public static func outermostAppPath(in executablePath: String) -> String? {
    guard let canonical = canonicalize(executablePath) else { return nil }
    let parts = canonical.split(separator: "/", omittingEmptySubsequences: true)
    for index in parts.indices where parts[index].lowercased().hasSuffix(".app") {
      guard parts[index].count > 4 else { continue }
      let next = parts.index(after: index)
      if next < parts.endIndex, parts[next].lowercased() == "contents" {
        return "/" + parts[parts.startIndex...index].joined(separator: "/")
      }
    }
    return nil
  }

  /// True for executables of the operating system that do not belong to an `.app`.
  public static func isSystemPath(_ canonicalPath: String) -> Bool {
    canonicalPath.hasPrefix("/System/") || canonicalPath.hasPrefix("/usr/")
  }
}
