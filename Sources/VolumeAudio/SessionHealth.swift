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
  /// Only absolute zeros arrived for `silenceLimit` of output time since the last real sample. Not a
  /// failure by itself: a browser may keep a silent stream open, and a revoked permission also
  /// gives zeros. Reported once per silent period.
  case silent
  /// The audio thread raised the kill switch.
  case faulted
}

/// Per-tap counters of the watchdog. Pure logic: the controller feeds it one sample per tick.
///
/// Silence is reported once and then latched until a non-zero sample arrives or `retryLater`
/// re-arms it, so a silent stream asks for at most one permission check every
/// `recheckAfter`, never in a loop and never "trusted" forever.
struct SessionHealth: Sendable {
  private let stallTicks: Int
  private let startTicks: Int
  private let silenceTicks: Int
  private let retryTicks: Int
  private var lastFrames: UInt64 = 0
  /// True once the IOProc delivered its first frame.
  private var started = false
  private var stalled = 0
  private var silent = 0
  private var reported = false
  private var checked = false

  init(policy: WatchdogPolicy) {
    stallTicks = policy.ticks(for: policy.stallLimit)
    startTicks = policy.ticks(for: policy.startLimit)
    silenceTicks = policy.ticks(for: policy.silenceLimit)
    retryTicks = policy.ticks(for: policy.recheckAfter)
  }

  /// True when this silent period already had a permission check: a new `.silent` is then a
  /// repeat, not the first silence after real sound.
  var silenceWasChecked: Bool { checked }

  /// Evaluates one tick. `sawSignal` is "a non-zero sample arrived since the last tick";
  /// `appRunning` is the app's `IsRunningOutput`. Silence is counted only while the app reports
  /// output, and only a non-zero sample resets the count: pausing never does, so a revoked
  /// permission with an app that plays on and off still reaches the check.
  mutating func evaluate(
    frames: UInt64, sawSignal: Bool, appRunning: Bool, fault: Bool
  ) -> HealthVerdict {
    if fault { return .faulted }
    if frames == lastFrames {
      stalled += 1
    } else {
      stalled = 0
      lastFrames = frames
      started = true
    }
    if stalled >= (started ? stallTicks : startTicks) { return .stalled }
    if sawSignal {
      silent = 0
      reported = false
      checked = false
    } else if appRunning && stalled == 0 {
      silent += 1
    }
    guard !reported, silent >= silenceTicks else { return .healthy }
    reported = true
    return .silent
  }

  /// The permission check after `.silent` ran: report the same silent period again after
  /// `recheckAfter`.
  mutating func retryLater() {
    checked = true
    reported = false
    silent = silenceTicks - retryTicks
  }
}
