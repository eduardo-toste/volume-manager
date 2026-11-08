import AppKit
import Foundation
import VolumeCore

/// `PermissionService` for the system audio permission (SPEC 5).
///
/// There is no public API that reads the permission without side effects, so the state comes
/// from the signal verification of the injected `AudioAccessProbe` (SPEC 4.6): real audio on a
/// test tap is `.granted`, only silence from a playing process is `.denied`. When nothing is playing the check is
/// indeterminate and the last known status is kept (the per-tap silence guard covers it).
/// Re-calling `request()` when the popover opens detects a grant made later in System Settings.
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

  /// Creates a test tap (showing the system prompt if undecided) and returns the new state.
  public func request() async -> AudioPermissionStatus {
    switch await probe.verify() {
    case .granted: lastKnown = .granted
    case .denied: lastKnown = .denied
    case .indeterminate: break
    }
    return lastKnown
  }

  /// Opens System Settings at the audio capture privacy pane.
  public nonisolated func openPrivacySettings() {
    guard let url = Self.privacySettingsURL else { return }
    openURL(url)
  }
}
