/// Timing of the "fail open" guards (SPEC 4.6).
struct WatchdogPolicy: Sendable, Hashable {
  /// How often active taps are checked. The check only runs while taps exist.
  var tick: Duration = .milliseconds(500)
  /// Frames must advance within this time.
  var stallLimit: Duration = .seconds(2)
  /// Digital silence while the app reports output for this long asks for a permission check.
  var silenceLimit: Duration = .seconds(2)
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
  /// Only absolute zeros arrived for `silenceLimit` while the app was reporting output. Not a
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
  private let silenceTicks: Int
  private let retryTicks: Int
  private var lastFrames: UInt64 = 0
  private var stalled = 0
  private var silent = 0
  private var reported = false

  init(policy: WatchdogPolicy) {
    stallTicks = policy.ticks(for: policy.stallLimit)
    silenceTicks = policy.ticks(for: policy.silenceLimit)
    retryTicks = policy.ticks(for: policy.recheckAfter)
  }

  /// Evaluates one tick. `sawSignal` is "a non-zero sample arrived since the last tick";
  /// `appRunning` is the app's `IsRunningOutput`.
  mutating func evaluate(
    frames: UInt64, sawSignal: Bool, appRunning: Bool, fault: Bool
  ) -> HealthVerdict {
    if fault { return .faulted }
    if frames == lastFrames {
      stalled += 1
    } else {
      stalled = 0
      lastFrames = frames
    }
    if stalled >= stallTicks { return .stalled }
    if sawSignal {
      silent = 0
      reported = false
    } else if appRunning && stalled == 0 {
      silent += 1
    } else if silent > 0 {
      silent = 0
    }
    guard !reported, silent >= silenceTicks else { return .healthy }
    reported = true
    return .silent
  }

  /// The permission check after `.silent` ran: report the same silent period again after
  /// `recheckAfter`.
  mutating func retryLater() {
    reported = false
    silent = silenceTicks - retryTicks
  }
}
