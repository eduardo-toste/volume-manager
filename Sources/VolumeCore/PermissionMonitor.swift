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
  /// never shows the system prompt by itself. Without it (a tap just went silent and the
  /// permission may have been revoked) it always checks. Ignored while a check is running.
  public func refresh(onlyIfDenied: Bool) async {
    guard !isRefreshing, !onlyIfDenied || status == .denied else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    let previous = status
    status = await service.request()
    if previous == .denied, status == .granted { onGranted() }
  }

  /// Opens System Settings at the audio capture privacy pane.
  public func openPrivacySettings() {
    service.openPrivacySettings()
  }
}
