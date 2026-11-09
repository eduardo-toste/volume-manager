import Observation

/// What the popover knows about the system audio permission (SPEC 3.2 and 5).
///
/// "Denied" is shown only after a signal verification said so: `.notDetermined` and an
/// indeterminate check (nothing was playing) never count as denied (SPEC 4.6).
@MainActor
@Observable
public final class PermissionMonitor {
  /// The last verified status.
  public private(set) var status = AudioPermissionStatus.notDetermined

  /// True when the popover must show the "no permission" state in place of the app list.
  public var isDenied: Bool { status == .denied }

  @ObservationIgnored private let service: any PermissionService
  /// Runs when the permission changes from denied to granted. `MixerStore` adds its retry.
  @ObservationIgnored public var onGranted: @MainActor () -> Void
  @ObservationIgnored private var isRefreshing = false

  /// Creates the monitor. It starts undecided (`status`), which keeps every tap blocked until
  /// a verification says `.granted`. `onGranted` runs when the permission changes from denied
  /// to granted, so failed apps can be retried.
  public init(
    service: any PermissionService, status: AudioPermissionStatus = .notDetermined,
    onGranted: @escaping @MainActor () -> Void = {}
  ) {
    self.status = status
    self.service = service
    self.onGranted = onGranted
  }

  /// Verifies the permission by signal (SPEC 4.6). With `onlyIfDenied` (the popover just
  /// opened, SPEC 5) it does nothing unless the permission is denied, so opening the popover
  /// never shows the system prompt by itself. Without it (a user action needs taps) it always
  /// checks. Returns the result of this check (`.notDetermined`: it could not conclude, and the
  /// last known status is kept), or `nil` when no check ran (another one is running, or
  /// `onlyIfDenied` and not denied). `userAction` is true only for a check the user asked for.
  @discardableResult
  public func refresh(onlyIfDenied: Bool, userAction: Bool = false) async -> AudioPermissionStatus?
  {
    guard !isRefreshing, !onlyIfDenied || status == .denied else { return nil }
    isRefreshing = true
    defer { isRefreshing = false }
    let previous = status
    let result = await service.request(userAction: userAction)
    if result != .notDetermined { status = result }
    if previous == .denied, status == .granted { onGranted() }
    return result
  }

  /// Opens System Settings at the audio capture privacy pane.
  public func openPrivacySettings() {
    service.openPrivacySettings()
  }
}
