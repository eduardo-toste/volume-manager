/// One row of the mixer: an app and all of its helper processes.
public struct AudioApp: Sendable, Hashable, Identifiable {
  /// Stable key of the app: its bundle ID, or `path:<app path>` when it has none.
  public let id: String
  /// Sanitized display name.
  public let name: String
  /// Valid bundle ID, used to remember settings. `nil` when the app has none.
  public let bundleID: String?
  /// PIDs of every process of the group, sorted.
  public let pids: [Int32]
  /// True when some process of the group is producing output.
  public let isPlaying: Bool
  /// True when some process of the group has input running: the app is in a call (SPEC 3.2).
  public let isInCall: Bool

  /// Creates an app group.
  public init(
    id: String, name: String, bundleID: String?, pids: [Int32], isPlaying: Bool,
    isInCall: Bool = false
  ) {
    self.id = id
    self.name = name
    self.bundleID = bundleID
    self.pids = pids
    self.isPlaying = isPlaying
    self.isInCall = isInCall
  }
}
