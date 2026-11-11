/// Timing of the "fail open" guards (SPEC 4.6).
struct WatchdogPolicy: Sendable, Hashable {
  /// How often active taps are checked. The check only runs while taps exist.
  var tick: Duration = .milliseconds(500)
  /// Once the first frame arrived, frames must keep advancing within this time.
  var stallLimit: Duration = .seconds(2)
  /// A new tap must deliver its first frame within this time (a Bluetooth device may be slow
  /// to wake up, SPEC 4.6).
  var startLimit: Duration = .seconds(5)
  /// Digital silence for this long, counting only the time the app reports output, asks for a
  /// permission check (SPEC 4.6: a voice call stays silent while nobody talks).
  var silenceLimit: Duration = .seconds(120)
  /// While a silence lasts, a new permission check is asked at most this often (after any
  /// result: a "granted" is never trusted forever, SPEC 4.6).
  var recheckAfter: Duration = .seconds(30)
  /// How long an old tap fades out while its replacement fades in.
  var crossfade: Duration = .milliseconds(40)

  /// Number of consecutive ticks that reach `limit` (at least 1).
  func ticks(for limit: Duration) -> Int {
    guard tick > .zero else { return 1 }
    let ratio = limit / tick
    return max(1, Int(ratio.rounded(.up)))
  }
}

/// What the periodic check concluded about one tap.
enum HealthVerdict: Sendable, Hashable {
  case healthy
  /// The IOProc stopped delivering frames.
  case stalled
  /// The audio thread raised the kill switch.
  case faulted
}

/// Per-tap stall and fault guard. Pure logic: the controller feeds it one sample per tick.
struct SessionHealth: Sendable {
  private let stallTicks: Int
  private let startTicks: Int
  private var lastFrames: UInt64 = 0
  /// True once the IOProc delivered its first frame.
  private var started = false
  private var stalled = 0

  init(policy: WatchdogPolicy) {
    stallTicks = policy.ticks(for: policy.stallLimit)
    startTicks = policy.ticks(for: policy.startLimit)
  }

  /// Evaluates one tick: frames must advance within `stallLimit` once the first frame arrived,
  /// and the first frame must arrive within `startLimit`.
  mutating func evaluate(frames: UInt64, fault: Bool) -> HealthVerdict {
    if fault { return .faulted }
    if frames == lastFrames {
      stalled += 1
    } else {
      stalled = 0
      lastFrames = frames
      started = true
    }
    return stalled >= (started ? stallTicks : startTicks) ? .stalled : .healthy
  }
}

/// The silence guard (SPEC 4.6): one for the whole controller, not one per tap, so the count
/// survives taps that are destroyed and rebuilt (pause longer than the linger, a process that
/// joins, another output, a `coreaudiod` restart; S53-A1). It counts the time some tapped app
/// reports output while no tap delivered any non-zero sample; only real sound on any tap resets
/// it, which also covers "another tap has sound: the permission works". Pure logic.
///
/// Silence is reported once and then latched until a non-zero sample arrives or `retryLater`
/// re-arms it, so a silent stream asks for at most one permission check every
/// `recheckAfter`, never in a loop and never "trusted" forever.
struct SilenceGuard: Sendable {
  private let silenceTicks: Int
  private let retryTicks: Int
  private var silent = 0
  private var reported = false
  private var checked = false

  init(policy: WatchdogPolicy) {
    silenceTicks = policy.ticks(for: policy.silenceLimit)
    retryTicks = policy.ticks(for: policy.recheckAfter)
  }

  /// True when this silent period already had a permission check: a new report is then a
  /// repeat, not the first silence after real sound.
  var silenceWasChecked: Bool { checked }

  /// Evaluates one tick. `sawSignal`: a non-zero sample arrived on any tap since the last
  /// tick; `outputRunning`: some tapped app reports `IsRunningOutput`. Returns true once when
  /// `silenceLimit` of output time passed without any real sample (pausing never resets it).
  mutating func evaluate(sawSignal: Bool, outputRunning: Bool) -> Bool {
    if sawSignal {
      silent = 0
      reported = false
      checked = false
    } else if outputRunning {
      silent += 1
    }
    guard !reported, silent >= silenceTicks else { return false }
    reported = true
    return true
  }

  /// The permission check after a report ran: report the same silent period again after
  /// `recheckAfter`.
  mutating func retryLater() {
    checked = true
    reported = false
    silent = silenceTicks - retryTicks
  }
}
