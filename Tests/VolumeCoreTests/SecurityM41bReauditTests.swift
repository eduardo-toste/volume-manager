import Testing

@testable import VolumeCore

/// Security re-audit M4.1b: the shared budget of automatic checks after the silence guard's
/// "denied", mixing its sources, and the way out of that state.
@MainActor
@Suite("Security M4.1b re-audit: shared automatic budget")
struct SecurityM41bReauditTests {
  /// Periodic timer and play starts together never exceed the budget; after it, a user action
  /// still checks (allowed: it follows the user) but stores no ambiguous denial, and a later
  /// "granted" brings the taps back and opens a fresh budget for a new episode.
  @Test func mixedSourcesShareTheBudgetAndAUserActionRecovers() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    // One play start, one periodic tick, then many play starts.
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: false)]))
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
    for _ in 0..<50 { await Task.yield() }
    _ = await eventually { h.clock.sleeperCount >= 1 }
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
    for _ in 0..<5 {
      h.store.handle(.processes([h.process("Safari", pid: 10, playing: false)]))
      h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
      for _ in 0..<50 { await Task.yield() }
    }
    h.clock.advance(by: MixerStore.permissionRecheckInterval * 4)
    for _ in 0..<50 { await Task.yield() }
    await h.settle()
    #expect(h.access.requests <= 1 + MixerStore.maxDeniedRechecks, "budget shared")
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "no tap while denied")

    // User action after the budget: a check runs, the ambiguous denial is not stored.
    let before = h.access.requests
    h.store.toggleMute("com.apple.Safari")
    await h.settle()
    #expect(h.access.requests == before + 1)
    #expect(h.settings.audioPermissionConfirmed)

    // Real sound later: the next user action grants, taps (with the mute) come back.
    h.access.answer = .granted
    h.store.setVolume(0.5, for: "com.apple.Safari")
    await h.settle()
    #expect(h.permission.status == .granted)
    #expect(h.controller.reconcileCalls.last?.first?.muted == true)

    // A new episode gets a fresh budget.
    h.access.answer = .denied
    let start = h.access.requests
    await h.store.checkSilentTap()
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: false)]))
    h.store.handle(.processes([h.process("Safari", pid: 10, playing: true)]))
    #expect(await eventually { h.access.requests == start + 2 })
  }
}
