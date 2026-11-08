import CoreAudio
import VolumeCore

/// Why a tap could not be created or was removed.
public struct AppAudioFailure: Sendable, Hashable {
  /// What went wrong.
  public enum Reason: Sendable, Hashable {
    /// Core Audio refused to create or start the tap or aggregate device.
    case creationFailed
    /// Tap and output cannot be joined without converting samples (SPEC 4.7).
    case incompatibleFormat
    /// The requested output device does not exist.
    case deviceUnavailable
    /// The IOProc stopped delivering frames while the tap was active (SPEC 4.6).
    case noAudioFrames
    /// Only digital silence arrived while the app reported output: the system audio
    /// permission is probably denied (SPEC 4.6). Verify with the access probe.
    case permissionLikelyDenied
    /// The audio thread found buffers it could not process safely.
    case ioFault
  }

  /// The app's stable key (`ControlledApp.id`).
  public let appID: String
  /// The reason.
  public let reason: Reason

  /// Creates a failure.
  public init(appID: String, reason: Reason) {
    self.appID = appID
    self.reason = reason
  }
}

/// A snapshot of one active tap for `vmctl` and diagnostics.
public struct TapDiagnostics: Sendable, Hashable {
  /// The app's key.
  public let appID: String
  /// PIDs the tap covers.
  public let pids: [Int32]
  /// Output device UID.
  public let deviceUID: String
  /// Frames processed since the tap started.
  public let framesProcessed: UInt64
  /// True if a non-zero sample ever reached the tap.
  public let hasSeenSignal: Bool
  /// Tap stream format, as text.
  public let tapFormat: String
  /// Output stream format, as text.
  public let outputFormat: String
  /// False when the listener for device format changes could not be installed; format changes
  /// are then only noticed by the next `reconcile`.
  public var isFormatMonitored = true
}

/// Something outside the app's control that may invalidate active taps.
enum EnvironmentChange: Sendable, Hashable {
  /// `coreaudiod` restarted: every Core Audio object ID is invalid.
  case serviceRestarted
  /// The format of an output device changed (sample rate, channels, profile).
  case deviceFormatChanged(uid: String)
}

/// Everything needed to start one tap.
struct TapRequest: Sendable {
  let app: ControlledApp
  /// PIDs that passed the identity check.
  let pids: [Int32]
  let device: DeviceSignature
  /// Gain the ramp starts from (1 replaces the original sound; 0 fades in beside another tap).
  let initialGain: Float
  let targetGain: Float
}

/// Errors from starting a tap.
enum TapError: Error, Sendable, Hashable {
  case processGone
  case cancelled
  case incompatibleFormat(FormatMismatch)
  case coreAudio(AudioError)
}

/// A running tap. All members are safe to call from any thread.
protocol TapHandle: Sendable {
  var framesProcessed: UInt64 { get }
  /// True if a non-zero sample arrived since the last call; clears the flag.
  func consumeSignalFlag() -> Bool
  var hasFault: Bool { get }
  func setTarget(gain: Float)
  func stop()
  var diagnostics: TapDiagnostics { get }
}

/// The Core Audio side of the controller, behind a protocol so the reconciliation logic can be
/// tested with fakes.
protocol TapEngine: Sendable {
  /// The output device with this UID and its format, or `nil` if it does not exist.
  func deviceSignature(uid: String) -> DeviceSignature?
  /// The PIDs of `app` that still pass the identity check.
  func confirmedPIDs(for app: ControlledApp) -> [Int32]
  /// True if any of the processes reports output now.
  func isRunningOutput(pids: [Int32]) -> Bool
  /// Creates and starts a tap. Returns only with the IOProc running, or throws having
  /// destroyed everything it created. `isCancelled` is checked between steps.
  func makeSession(_ request: TapRequest, isCancelled: @Sendable () -> Bool) throws(TapError)
    -> any TapHandle
  /// A stream of environment changes.
  func environmentChanges() -> AsyncStream<EnvironmentChange>
}
