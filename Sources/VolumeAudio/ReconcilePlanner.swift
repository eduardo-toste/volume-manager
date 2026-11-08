import VolumeCore

/// What identifies a running tap. Anything that differs means the tap must be rebuilt;
/// volume and mute are not part of it (they only move an atomic, SPEC 12.4).
struct SessionKey: Sendable, Hashable {
  let pids: [Int32]
  let deviceUID: String
  let device: DeviceSignature
  let serviceGeneration: Int
}

/// The decision for one app.
enum SessionPlan: Sendable, Hashable {
  /// Nothing exists and nothing is wanted.
  case none
  /// Create a tap.
  case create
  /// Keep the tap and only update gain and mute.
  case update
  /// The old tap is still valid: start the new one beside it and cross-fade.
  case replaceGracefully
  /// The old tap is invalid (format or `coreaudiod` changed): destroy it, then create.
  case replaceHard
  /// Destroy the tap (the app is no longer wanted).
  case destroy
}

enum ReconcilePlanner {
  /// Decides what to do for one app (SPEC 12.4, 12.1; M0.5 recommendations 9 and 11).
  static func plan(current: SessionKey?, wanted: SessionKey?) -> SessionPlan {
    switch (current, wanted) {
    case (nil, nil): return .none
    case (nil, .some): return .create
    case (.some, nil): return .destroy
    case (.some(let old), .some(let new)):
      if old == new { return .update }
      let formatChanged = old.deviceUID == new.deviceUID && old.device != new.device
      if old.serviceGeneration != new.serviceGeneration || formatChanged {
        return .replaceHard
      }
      return .replaceGracefully
    }
  }
}
