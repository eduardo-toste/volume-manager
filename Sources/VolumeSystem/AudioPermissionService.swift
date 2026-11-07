import AppKit
import Foundation
import VolumeCore

/// `PermissionService` for the system audio permission (SPEC 5).
///
/// There is no public API that reads the permission without side effects, so the state comes
/// from the result of a test tap made by the injected `AudioAccessProbe`. `currentStatus()`
/// never probes (it would show the prompt at the wrong moment); it returns the last known
/// result, `.notDetermined` before any request. `request()` probes: success is `.granted`,
/// failure is `.denied`. Re-calling `request()` when the popover opens detects a grant made
/// later in System Settings.
public actor AudioPermissionService: PermissionService {
  /// Fixed deep link to Privacy & Security > System Audio Recording.
  static let privacySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")

  private let probe: any AudioAccessProbe
  private let openURL: @Sendable (URL) -> Void
  private var lastKnown: AudioPermissionStatus = .notDetermined

  /// Creates the service with the real probe supplied by the composition root.
  public init(probe: any AudioAccessProbe) {
    self.init(probe: probe, openURL: { NSWorkspace.shared.open($0) })
  }

  init(probe: any AudioAccessProbe, openURL: @escaping @Sendable (URL) -> Void) {
    self.probe = probe
    self.openURL = openURL
  }

  /// The last known state; does not touch the system.
  public func currentStatus() async -> AudioPermissionStatus {
    lastKnown
  }

  /// Creates a test tap (showing the system prompt if undecided) and returns the new state.
  public func request() async -> AudioPermissionStatus {
    let granted = probe.probe()
    lastKnown = granted ? .granted : .denied
    return lastKnown
  }

  /// Opens System Settings at the audio capture privacy pane.
  public nonisolated func openPrivacySettings() {
    guard let url = Self.privacySettingsURL else { return }
    openURL(url)
  }
}
