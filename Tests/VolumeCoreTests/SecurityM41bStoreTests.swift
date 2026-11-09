import Testing

@testable import VolumeCore

/// Security audit M4.1b: the automatic permission checks after the silence guard's "denied".
/// Each automatic check runs a test tap; with the permission reset in System Settings ("not
/// decided") a test tap shows the system prompt without a user action (SPEC 5). These tests
/// count those automatic checks.
@MainActor
@Suite("Security M4.1b: automatic checks after an ambiguous denied", .timeLimit(.minutes(1)))
struct SecurityM41bStoreTests {
  private func waitAndAdvance(_ h: MixerHarness) async {
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    for _ in 0..<50 { await Task.yield() }
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
  }

  /// S41b-B1 (fixed): play starts after the silence guard's "denied" share the budget of
  /// `maxDeniedRechecks` automatic checks with the periodic timer.
  @Test func playStartsAfterAnAmbiguousDenialStayInsideTheAutomaticBudget() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    #expect(h.access.requests == 1)
    for _ in 1...10 {
      h.store.handle(.processes([h.process("Safari", pid: 10, playing: false)]))
      h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
      for _ in 0..<50 { await Task.yield() }
    }
    await h.settle()
    #expect(h.access.requests == 1 + MixerStore.maxDeniedRechecks, "only the budget")
    #expect(h.permission.isDenied)
  }

  /// S41b-B1 and B2 (fixed): the periodic timer spends the same budget, and after it no
  /// further automatic check runs and the ambiguous denial is never stored (SPEC 4.6).
  @Test func afterTheBudgetNothingMoreRunsAndNothingIsPersisted() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    for _ in 1...MixerStore.maxDeniedRechecks { await waitAndAdvance(h) }
    #expect(await eventually { h.access.requests == 1 + MixerStore.maxDeniedRechecks })
    #expect(h.settings.audioPermissionConfirmed)

    h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: false)]))
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
    await h.settle()
    for _ in 0..<50 { await Task.yield() }
    #expect(h.access.requests == 1 + MixerStore.maxDeniedRechecks, "no more automatic checks")
    #expect(h.settings.audioPermissionConfirmed, "the ambiguous denial is not persisted")
  }
}
