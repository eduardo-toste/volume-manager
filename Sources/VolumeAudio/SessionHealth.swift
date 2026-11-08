/// Timing of the "fail open" guards (SPEC 4.6).
struct WatchdogPolicy: Sendable, Hashable {
  /// How often active taps are checked. The check only runs while taps exist.
  var tick: Duration = .milliseconds(500)
  /// Frames must advance within this time.
  var stallLimit: Duration = .seconds(2)
  /// Digital silence while the app reports output is tolerated this long.
  var silenceLimit: Duration = .seconds(2)
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
  /// Only absolute zeros arrived while the app was reporting output.
  case silent
  /// The audio thread raised the kill switch.
  case faulted
}

/// Per-tap counters of the watchdog. Pure logic: the controller feeds it one sample per tick.
struct SessionHealth: Sendable {
  private let stallTicks: Int
  private let silenceTicks: Int
  private var lastFrames: UInt64 = 0
  private var stalled = 0
  private var silent = 0

  init(policy: WatchdogPolicy) {
    stallTicks = policy.ticks(for: policy.stallLimit)
    silenceTicks = policy.ticks(for: policy.silenceLimit)
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
    if appRunning && !sawSignal && stalled == 0 {
      silent += 1
    } else {
      silent = 0
    }
    return silent >= silenceTicks ? .silent : .healthy
  }
}
