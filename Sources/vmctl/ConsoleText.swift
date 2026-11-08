import VolumeCore

/// Text for the terminal output of the development tool. Everything that comes from another
/// process or device is untrusted and could carry terminal escape sequences, so it is cleaned
/// with `TextSanitizer` before it is printed (SPEC 12.9.4, review finding B-1).
enum ConsoleText {
  /// Longest printed path, in characters.
  static let maxPathLength = 1024

  /// `text` cleaned and shortened, or `-` when it is missing or empty after cleaning.
  static func safe(_ text: String?, limit: Int = TextSanitizer.maxLength) -> String {
    guard let text else { return "-" }
    let clean = TextSanitizer.clean(text, limit: limit)
    return clean.isEmpty ? "-" : clean
  }

  /// One line for the list of audio processes.
  static func line(for process: AudioProcessInfo) -> String {
    "\(process.pid)\t\(process.isRunningOutput ? "PLAYING" : "idle   ")\t"
      + "\(safe(process.bundleID))\t\(safe(process.executablePath, limit: maxPathLength))"
      + (process.responsiblePID.map { "\tresponsible=\($0)" } ?? "")
  }

  /// One line for a grouped app.
  static func line(for app: AudioApp) -> String {
    let pids = app.pids.map(String.init).joined(separator: ",")
    return "\(app.isPlaying ? "[PLAYING]" : "[idle]   ") \(safe(app.name)) "
      + "<\(safe(app.bundleID ?? app.id))> pids: \(pids)"
  }
}
