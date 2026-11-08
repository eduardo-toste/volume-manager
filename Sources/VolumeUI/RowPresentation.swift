import Foundation
import VolumeCore

/// What one mixer row shows, derived from the domain. Pure, so it can be tested.
struct RowPresentation {
  let row: MixerRow

  /// Name of the app, or a localized placeholder when its name is empty after sanitizing.
  var appName: String {
    row.app.name.isEmpty ? String(localized: "app.unnamed", bundle: .main) : row.app.name
  }

  /// Volume as a whole percent, `0...100`.
  var percent: Int { Self.percent(row.state.volume) }
  /// True when the row shows "Silenciado" instead of the percent.
  var isMuted: Bool { row.state.muted }
  /// Name of the output when it is not the system default, for the accent label.
  var routeName: String? { row.usesSystemDefault ? nil : row.device?.displayName }

  /// VoiceOver text, for example "Spotify, volume 72 por cento, saída AirPods Pro".
  func accessibilityLabel(failed: Bool) -> String {
    if failed {
      return String(format: String(localized: "a11y.row.failed", bundle: .main), appName)
    }
    let device = row.device?.displayName ?? String(localized: "device.unknown", bundle: .main)
    if isMuted {
      return String(
        format: String(localized: "a11y.row.muted", bundle: .main), appName, device)
    }
    return String(
      format: String(localized: "a11y.row", bundle: .main), appName, percent, device)
  }

  /// A slider position as a whole percent, `0...100`.
  static func percent(_ volume: Double) -> Int {
    Int((VolumeCurve.clampedVolume(volume) * 100).rounded())
  }

  /// The position after moving a signed number of `steps`, kept on whole percents.
  static func stepped(_ volume: Double, by step: VolumeStep, steps: Int) -> Double {
    let moved = VolumeCurve.clampedVolume(volume) + step.fraction * Double(steps)
    return VolumeCurve.clampedVolume((moved * 100).rounded() / 100)
  }
}

extension OutputDeviceKind {
  /// SF Symbol for the device.
  var symbolName: String {
    switch self {
    case .builtIn: "speaker.wave.2.fill"
    case .usb: "cable.connector"
    case .bluetooth: "headphones"
    case .display: "display"
    case .airPlay: "airplayaudio"
    case .virtual: "waveform"
    case .other: "speaker.wave.2.fill"
    }
  }
}

extension OutputDevice {
  /// Name to show: a localized placeholder when the name is empty after sanitizing.
  var displayName: String {
    name.isEmpty ? String(localized: "device.unnamed", bundle: .main) : name
  }
}
