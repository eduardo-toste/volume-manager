import Foundation
import Testing

extension Tag {
  /// Tests that need real audio hardware (SPEC 12.8.1). Skipped unless `scripts/check.sh --audio`.
  @Tag static var audioHardware: Self
}

extension Trait where Self == ConditionTrait {
  /// Enables a test only when the audio-hardware run was requested.
  static var requiresAudioHardware: Self {
    enabled(
      if: ProcessInfo.processInfo.environment["VOLUME_AUDIO_TESTS"] == "1",
      "Run scripts/check.sh --audio to enable hardware audio tests")
  }
}
