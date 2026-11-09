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
    /// The audio thread found buffers it could not process safely.
    case ioFault
    /// Not a failure: the tap carried only digital silence for 5 s after real sound while the
    /// app reports output. The tap is kept; the permission must be checked (SPEC 4.6), because
    /// a revoked permission also delivers only zeros.
    case onlySilence
    /// Like `onlySilence`, but the same silent period was already checked: a recent "granted"
    /// may answer it (SPEC 4.6).
    case stillSilent
    /// Not a failure: the app stopped reporting output. The domain re-reads the processes so
    /// the tap goes away after the linger period (SPEC 4.2).
    case stoppedPlaying
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

/// A process that passed the identity check, with the Core Audio object it was resolved to.
/// The object is resolved once and used for the tap, so a PID reused in between cannot make
/// the tap cover another process (review finding B-4).
struct ConfirmedProcess: Sendable, Hashable {
  let pid: Int32
  let objectID: AudioObjectID
}

/// Everything needed to start one tap.
struct TapRequest: Sendable {
  let app: ControlledApp
  /// Processes that passed the identity check, each with its object resolved once.
  let processes: [ConfirmedProcess]
  let device: DeviceSignature
  /// Gain the ramp starts from (1 replaces the original sound; 0 fades in beside another tap).
  let initialGain: Float
  let targetGain: Float

  var pids: [Int32] { processes.map(\.pid) }
  var objectIDs: [AudioObjectID] { processes.map(\.objectID) }
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
  /// Forgets the Core Audio objects without destroying them (the server restarted and already
  /// lost them; the old IDs must not be used).
  func abandon()
  var diagnostics: TapDiagnostics { get }
}

/// The Core Audio side of the controller, behind a protocol so the reconciliation logic can be
/// tested with fakes.
protocol TapEngine: Sendable {
  /// The output device with this UID and its format, or `nil` if it does not exist.
  func deviceSignature(uid: String) -> DeviceSignature?
  /// The processes of `app` that still pass the identity check, each resolved to its Core
  /// Audio object exactly once.
  func confirmedProcesses(for app: ControlledApp) -> [ConfirmedProcess]
  /// True if any of the processes reports output now.
  func isRunningOutput(pids: [Int32]) -> Bool
  /// Creates and starts a tap. Returns only with the IOProc running, or throws having
  /// destroyed everything it created. `isCancelled` is checked between steps.
  func makeSession(_ request: TapRequest, isCancelled: @Sendable () -> Bool) throws(TapError)
    -> any TapHandle
  /// A stream of environment changes.
  func environmentChanges() -> AsyncStream<EnvironmentChange>
}
