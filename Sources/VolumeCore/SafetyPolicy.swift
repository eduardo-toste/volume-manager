import Observation

/// Safe mode (SPEC 4.6): after two abnormal terminations in a row, each less than a minute
/// after the app started, the next start does not reapply remembered volumes and routes.
///
/// A session is "stable" once it has run for a minute. A start that finds the previous session
/// neither stable nor cleanly closed counts it as an early abnormal termination.
@MainActor
@Observable
public final class SafetyPolicy {
  /// Storage keys.
  enum Key {
    static let started = "safety.sessionStarted"
    static let cleanExit = "safety.cleanExit"
    static let stable = "safety.stable"
    static let earlyCrashes = "safety.earlyCrashes"
  }

  /// How long a session must run to count as stable.
  public static let stableSessionDuration: Duration = .seconds(60)
  /// Consecutive early abnormal terminations that trigger safe mode.
  public static let crashThreshold = 2

  /// True when remembered volumes and routes must not be applied in this session.
  public private(set) var isSafeMode = false

  @ObservationIgnored private let store: any PreferencesStore
  @ObservationIgnored private let clock: AppClock
  @ObservationIgnored private var stableTask: Task<Void, Never>?

  /// Creates the policy. Call `beginSession()` once at launch.
  public init(store: any PreferencesStore, clock: AppClock) {
    self.store = store
    self.clock = clock
  }

  /// Reads how the previous session ended, decides on safe mode, records the new session and
  /// starts the timer that marks it stable.
  public func beginSession() {
    let hadSession = PreferenceValidation.bool(store.object(forKey: Key.started)) ?? false
    let clean = PreferenceValidation.bool(store.object(forKey: Key.cleanExit)) ?? false
    let stable = PreferenceValidation.bool(store.object(forKey: Key.stable)) ?? false
    var crashes = min(
      max(PreferenceValidation.integer(store.object(forKey: Key.earlyCrashes)) ?? 0, 0), 100)
    if hadSession { crashes = (clean || stable) ? 0 : crashes + 1 }
    isSafeMode = crashes >= Self.crashThreshold
    write(crashes: crashes, clean: false, stable: false)
    stableTask?.cancel()
    stableTask = Task { [weak self, clock] in
      do { try await clock.sleep(for: SafetyPolicy.stableSessionDuration) } catch { return }
      self?.markStable()
    }
  }

  /// Records a normal quit. Call when the app terminates through its own menu.
  public func markCleanExit() {
    stableTask?.cancel()
    stableTask = nil
    store.set(true, forKey: Key.cleanExit)
    store.set(0, forKey: Key.earlyCrashes)
  }

  private func markStable() {
    write(crashes: 0, clean: false, stable: true)
  }

  private func write(crashes: Int, clean: Bool, stable: Bool) {
    store.set(true, forKey: Key.started)
    store.set(clean, forKey: Key.cleanExit)
    store.set(stable, forKey: Key.stable)
    store.set(crashes, forKey: Key.earlyCrashes)
  }
}
