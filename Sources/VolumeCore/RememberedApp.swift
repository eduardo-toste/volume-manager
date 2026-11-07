import Foundation

/// What is remembered for an app, by bundle ID (SPEC 4.5).
public struct RememberedApp: Sendable, Hashable {
  /// Volume in `0...1`.
  public let volume: Double
  /// True if the app was muted.
  public let muted: Bool
  /// UID of the saved output, or `nil` for the system default.
  public let outputUID: String?

  /// Creates a record. The volume is clamped to `0...1`.
  public init(volume: Double, muted: Bool, outputUID: String?) {
    self.volume = VolumeCurve.clampedVolume(volume)
    self.muted = muted
    self.outputUID = outputUID
  }

  /// Builds a record from an app state.
  public init(_ state: AppAudioState) {
    self.init(volume: state.volume, muted: state.muted, outputUID: state.preferredOutputUID)
  }

  /// The state to apply when the app comes back.
  public var state: AppAudioState {
    AppAudioState(volume: volume, muted: muted, preferredOutputUID: outputUID)
  }

  /// Reads a record from storage. The record itself must be a dictionary; each field that is
  /// invalid falls back to its safe default (100%, not muted, system default output).
  init?(validating raw: Any?) {
    guard let dictionary = raw as? [String: Any] else { return nil }
    self.init(
      volume: PreferenceValidation.volume(dictionary["volume"]) ?? 1,
      muted: PreferenceValidation.bool(dictionary["muted"]) ?? false,
      outputUID: PreferenceValidation.uid(dictionary["outputUID"]))
  }

  /// The storable form.
  var propertyList: [String: Any] {
    var result: [String: Any] = ["volume": volume, "muted": muted]
    if let outputUID { result["outputUID"] = outputUID }
    return result
  }
}
