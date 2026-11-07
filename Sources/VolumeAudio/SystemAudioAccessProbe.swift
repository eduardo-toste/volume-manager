import CoreAudio
import Foundation
import VolumeCore

/// Real `AudioAccessProbe`: creates a minimal global tap and destroys it immediately.
///
/// The tap is private, unmuted, has no aggregate device and no IOProc, so it neither touches
/// nor plays any audio. If the permission is still undecided, creating it shows the system
/// prompt (that is the point of the Allow button).
public struct SystemAudioAccessProbe: AudioAccessProbe {
  /// Creates the probe. It holds no state.
  public init() {}

  /// Creates and destroys one test tap; see `AudioAccessProbe.probe()`.
  public func probe() -> Bool {
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    description.name = "Volume access check"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tapID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
      tapID != AudioObjectID(kAudioObjectUnknown)
    else { return false }
    _ = AudioHardwareDestroyProcessTap(tapID)
    return true
  }
}
