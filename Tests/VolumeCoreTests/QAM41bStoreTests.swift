import Testing

@testable import VolumeCore

/// QA M4.1b: edge cases of the ambiguous denial (SPEC 4.6, S41R-B1).
@MainActor
@Suite("QA M4.1b: ambiguous denial edges", .timeLimit(.minutes(1)))
struct QAM41bStoreTests {
  /// A permission that was never confirmed on this Mac is not checked again by the timer.
  @Test func noAutomaticRecheckWhenThePermissionWasNeverConfirmed() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = false
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    let before = h.access.requests
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    for _ in 0..<50 { await Task.yield() }
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
    #expect(h.access.requests == before)
  }

  /// The "sound returned" checks share the automatic budget, so playing and stopping again
  /// does not ask the system again and again.
  @Test func soundReturningChecksOnlyOnceWhileStillDenied() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    h.start([h.process("Safari", pid: 10, playing: false)])
    h.start([h.process("Safari", pid: 10, playing: true)])
    #expect(await eventually { h.access.requests >= 2 })
    for _ in 0..<50 { await Task.yield() }
    let after = h.access.requests
    for _ in 0..<3 {
      h.start([h.process("Safari", pid: 10, playing: false)])
      h.start([h.process("Safari", pid: 10, playing: true)])
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(h.access.requests <= 1 + MixerStore.maxDeniedRechecks, "inside the shared budget")
    #expect(after <= 1 + MixerStore.maxDeniedRechecks)
  }

  /// QA round 2: with the automatic budget spent, opening the popover still checks, and a
  /// "granted" brings the taps back; nothing is left muted.
  @Test func openingThePopoverStillChecksAfterTheBudgetIsSpent() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    for _ in 0..<(MixerStore.maxDeniedRechecks + 2) {
      h.start([h.process("Safari", pid: 10, playing: false)])
      h.start([h.process("Safari", pid: 10, playing: true)])
      for _ in 0..<50 { await Task.yield() }
    }
    let spent = h.access.requests
    for _ in 0..<50 { await Task.yield() }
    h.clock.advance(by: MixerStore.permissionRecheckInterval * 4)
    for _ in 0..<50 { await Task.yield() }
    #expect(h.access.requests == spent, "no more automatic checks")
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "original sound")
    h.access.answer = .granted
    await h.permission.refresh(onlyIfDenied: true)
    await h.settle()
    #expect(h.access.requests == spent + 1)
    #expect(h.permission.status == .granted)
    #expect(h.controller.reconcileCalls.last?.isEmpty == false, "taps are back")
  }
}
