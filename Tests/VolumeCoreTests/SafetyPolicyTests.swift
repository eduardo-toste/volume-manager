import Testing

@testable import VolumeCore

@MainActor
@Suite("SafetyPolicy", .timeLimit(.minutes(1)))
struct SafetyPolicyTests {
  let clock = FakeClock()
  let store = InMemoryPreferencesStore()

  private func launch() -> SafetyPolicy {
    let policy = SafetyPolicy(store: store, clock: clock)
    policy.beginSession()
    return policy
  }

  @Test func firstLaunchIsNotSafeMode() {
    #expect(!launch().isSafeMode)
  }

  @Test func oneEarlyCrashIsNotEnough() {
    _ = launch()
    #expect(!launch().isSafeMode)
  }

  @Test func twoEarlyCrashesInARowEnterSafeMode() {
    _ = launch()
    _ = launch()
    #expect(launch().isSafeMode)
  }

  @Test func safeModePersistsWhileCrashesContinue() {
    for _ in 0..<5 { _ = launch() }
    #expect(launch().isSafeMode)
  }

  @Test func aCleanExitResetsTheCount() {
    _ = launch()
    let second = launch()
    second.markCleanExit()
    #expect(!launch().isSafeMode)
    #expect(!launch().isSafeMode)
  }

  @Test func aStableSessionResetsTheCount() async {
    _ = launch()
    let second = launch()
    #expect(second.isSafeMode == false)
    #expect(await eventually { clock.sleeperCount == 2 })
    clock.advance(by: SafetyPolicy.stableSessionDuration)
    #expect(await eventually { store.values["safety.stable"] as? Bool == true })
    #expect(!launch().isSafeMode)
    #expect(!launch().isSafeMode)
  }

  @Test func theStableTimerIsOneMinute() async {
    #expect(SafetyPolicy.stableSessionDuration == .seconds(60))
    _ = launch()
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .seconds(59))
    await Task.yield()
    #expect(store.values["safety.stable"] as? Bool == false)
  }

  @Test func safeModeSessionThatBecomesStableRecovers() async {
    _ = launch()
    _ = launch()
    let safe = launch()
    #expect(safe.isSafeMode)
    #expect(await eventually { clock.sleeperCount == 3 })
    clock.advance(by: .seconds(60))
    #expect(await eventually { store.values["safety.stable"] as? Bool == true })
    #expect(safe.isSafeMode, "safe mode lasts for the whole session")
    #expect(!launch().isSafeMode)
  }

  @Test func cleanExitCancelsTheStableTimer() async {
    let policy = launch()
    #expect(await eventually { clock.sleeperCount == 1 })
    policy.markCleanExit()
    #expect(await eventually { clock.sleeperCount == 0 })
    #expect(store.values["safety.cleanExit"] as? Bool == true)
  }

  @Test func corruptedRecordsMeanNoCrashHistory() {
    let hostile = InMemoryPreferencesStore([
      "safety.sessionStarted": "yes", "safety.cleanExit": 3, "safety.stable": [],
      "safety.earlyCrashes": "many",
    ])
    let policy = SafetyPolicy(store: hostile, clock: clock)
    policy.beginSession()
    #expect(!policy.isSafeMode)
  }

  @Test func absurdStoredCountersAreClamped() {
    let hostile = InMemoryPreferencesStore([
      "safety.sessionStarted": true, "safety.cleanExit": false, "safety.stable": false,
      "safety.earlyCrashes": -50,
    ])
    let policy = SafetyPolicy(store: hostile, clock: clock)
    policy.beginSession()
    #expect(!policy.isSafeMode)
    #expect(hostile.values["safety.earlyCrashes"] as? Int == 1)
  }

  @Test func previousSessionEndedCleanlyOnlyAfterAMarkedCleanExit() {
    #expect(!launch().previousSessionEndedCleanly, "first launch: no record")
    #expect(!launch().previousSessionEndedCleanly, "the first session never ended")
    let session = launch()
    session.markCleanExit()
    #expect(launch().previousSessionEndedCleanly)
    #expect(!launch().previousSessionEndedCleanly, "that one ended without a clean exit")
  }

  /// M6, end to end: two early crashes, then a start in safe mode that exits cleanly, then a
  /// normal start that applies what was remembered.
  @Test func safeModeEndsAfterACleanExitAndRememberedVolumesReturn() async {
    let remembered: [String: Any] = [
      "rememberedApps": ["com.spotify.client": ["volume": 0.3, "muted": false]] as [String: Any]
    ]
    var saved = remembered
    func start() -> MixerHarness {
      let h = MixerHarness(preferences: saved, beginSafety: true)
      h.start([h.process("Spotify", pid: 1, playing: true)])
      saved = h.preferences.values
      return h
    }
    _ = start()
    _ = start()
    let inSafeMode = start()
    #expect(inSafeMode.store.isSafeMode)
    #expect(inSafeMode.store.rows.first?.state == .default)
    inSafeMode.safety.markCleanExit()
    saved = inSafeMode.preferences.values
    let normal = start()
    #expect(!normal.store.isSafeMode)
    #expect(normal.store.rows.first?.state.volume == 0.3)
  }
}
