/// The output an app actually plays on.
public struct EffectiveRoute: Sendable, Hashable {
  /// UID of the device.
  public let deviceUID: String
  /// True when the app follows the system default output (no special routing needed).
  public let usesSystemDefault: Bool

  /// Creates a route.
  public init(deviceUID: String, usesSystemDefault: Bool) {
    self.deviceUID = deviceUID
    self.usesSystemDefault = usesSystemDefault
  }
}

/// Decides the effective output of an app (SPEC 4.3).
public enum RoutingPolicy {
  /// The preferred device when it is connected and not the default; otherwise the system
  /// default. The preference is never discarded here, so the route comes back by itself when
  /// the device reappears. Returns `nil` when no default output is known and the preferred
  /// device is absent (callers then leave the app untouched).
  public static func resolve(
    preferredUID: String?, devices: [OutputDevice], defaultUID: String?
  ) -> EffectiveRoute? {
    if let preferredUID, preferredUID != defaultUID,
      devices.contains(where: { $0.uid == preferredUID })
    {
      return EffectiveRoute(deviceUID: preferredUID, usesSystemDefault: false)
    }
    guard let defaultUID else { return nil }
    return EffectiveRoute(deviceUID: defaultUID, usesSystemDefault: true)
  }

  /// True when the app has a saved route whose device is not connected right now.
  public static func isPreferredDeviceMissing(
    preferredUID: String?, devices: [OutputDevice]
  ) -> Bool {
    guard let preferredUID else { return false }
    return !devices.contains(where: { $0.uid == preferredUID })
  }
}
