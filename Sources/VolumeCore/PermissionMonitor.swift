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

  @ObservationIgnored private let service: any PermissionService
  /// Runs when the permission changes from denied to granted. `MixerStore` adds its retry.
  @ObservationIgnored public var onGranted: @MainActor () -> Void
  @ObservationIgnored private var isRefreshing = false
  /// Callers that asked while a check was running; they get that check's result.
  @ObservationIgnored private var waiters: [CheckedContinuation<AudioPermissionStatus, Never>] = []

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
  /// last known status is kept), or `nil` when no check ran (`onlyIfDenied` and not denied).
  /// When another check is already running, waits for it and returns its result, so a click on
  /// "Permitir…" during the automatic check at launch shows that check's answer; only a
  /// `userAction` after an inconclusive answer then runs its own check (it may show the system
  /// prompt). `userAction` is true only for a check the user asked for.
  @discardableResult
  public func refresh(onlyIfDenied: Bool, userAction: Bool = false) async -> AudioPermissionStatus?
  {
    guard !onlyIfDenied || status == .denied else { return nil }
    if isRefreshing {
      let waited = await withCheckedContinuation { waiters.append($0) }
      if waited != .notDetermined || !userAction { return waited }
      if isRefreshing { return waited }
    }
    isRefreshing = true
    let previous = status
    var result = await service.request(userAction: userAction)
    // A check cut short by cancellation proves no denial (S53R-B1).
    if Task.isCancelled, result == .denied { result = .notDetermined }
    if result != .notDetermined { status = result }
    isRefreshing = false
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(returning: result) }
    if previous == .denied, status == .granted { onGranted() }
    return result
  }

  /// Opens System Settings at the audio capture privacy pane.
  public func openPrivacySettings() {
    service.openPrivacySettings()
  }
}
