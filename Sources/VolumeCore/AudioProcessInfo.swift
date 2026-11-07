/// A process that Core Audio lists as an audio client. All text fields are untrusted.
public struct AudioProcessInfo: Sendable, Hashable {
  /// Process identifier.
  public let pid: Int32
  /// Bundle identifier reported by Core Audio, if any.
  public let bundleID: String?
  /// Executable path, if known.
  public let executablePath: String?
  /// PID of the process the system holds responsible for this one, if known.
  public let responsiblePID: Int32?
  /// True while the process is producing output.
  public let isRunningOutput: Bool

  /// Creates a process description.
  public init(
    pid: Int32,
    bundleID: String? = nil,
    executablePath: String? = nil,
    responsiblePID: Int32? = nil,
    isRunningOutput: Bool = false
  ) {
    self.pid = pid
    self.bundleID = bundleID
    self.executablePath = executablePath
    self.responsiblePID = responsiblePID
    self.isRunningOutput = isRunningOutput
  }
}
