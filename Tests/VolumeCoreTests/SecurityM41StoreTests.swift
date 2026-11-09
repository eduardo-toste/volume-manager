import Testing

@testable import VolumeCore

/// Security audit M4.1, round 6: a "denied" from the silence check is ambiguous (a browser with
/// an open silent stream may be the only player). The fix keeps the fail-open behaviour and
/// removes the lasting harm.
@MainActor
@Suite("Security M4.1: ambiguous denied after silence", .timeLimit(.minutes(1)))
struct SecurityM41StoreTests {
  private let safari = "com.apple.Safari"

  /// S41-M1 (fixed): the taps go at once (fail open) and the popover shows the "no permission"
  /// state in place of the rows, but the denial is not stored, and a later check with real
  /// sound brings the user's mute back.
  @Test func ambiguousDeniedIsNotStoredAndTheTapsComeBack() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    h.store.toggleMute(safari)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.muted == true)

    h.access.answer = .denied
    await h.store.checkSilentTap()
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "fail open: original sound")
    #expect(h.permission.isDenied, "the popover replaces the rows with the notice")
    #expect(h.settings.audioPermissionConfirmed, "not stored across launches")

    h.access.answer = .granted
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    #expect(await eventually { h.permission.status == .granted })
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.muted == true, "the mute applies again")
  }

  /// S41R-B1: while the permission stays denied, the automatic checks stop after a few tries, so
  /// a permission reset in System Settings cannot make them show the system prompt for ever.
  @Test func automaticRechecksWhileDeniedStopAfterAFewTries() async {
    let h = MixerHarness(permission: .granted)
    h.settings.audioPermissionConfirmed = true
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    #expect(h.access.requests == 1)
    for round in 1...MixerStore.maxDeniedRechecks {
      #expect(await eventually { h.clock.sleeperCount >= 1 })
      for _ in 0..<50 { await Task.yield() }
      h.clock.advance(by: MixerStore.permissionRecheckInterval)
      #expect(await eventually { h.access.requests == 1 + round })
    }
    for _ in 0..<50 { await Task.yield() }
    h.clock.advance(by: MixerStore.permissionRecheckInterval * 3)
    for _ in 0..<50 { await Task.yield() }
    #expect(h.access.requests == 1 + MixerStore.maxDeniedRechecks, "no further automatic check")
    #expect(h.permission.isDenied)
  }

  /// S41-A1 in the domain: a grant is reused for 30 s only; the next check after that runs a
  /// real test tap, and a "denied" then removes every tap.
  @Test func aRevocationAfterAGrantedSilenceRemovesEveryTapAtTheNextCheck() async {
    let h = MixerHarness(permission: .granted)
    h.start([
      h.process("Safari", pid: 10, playing: true), h.process("Spotify", pid: 11, playing: true),
    ])
    await h.settle()
    h.access.answer = .granted
    await h.store.checkSilentTap()
    h.access.answer = .denied  // revoked while the Volume runs
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
    await h.store.checkSilentTap()
    await h.settle()
    #expect(h.access.requests == 2)
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "no app stays mute")
  }

  /// Re-audit (S41R-M1): within 30 s of a cached grant, a fresh silence report (for example from
  /// an app that was playing real sound and went mute because the permission was just revoked)
  /// runs no check and keeps every tap. The mute is bounded by the cache (about 30 s).
  @Test func aCachedGrantAnswersAFreshSilenceWithoutACheck() async {
    let h = MixerHarness(permission: .granted)
    h.start([
      h.process("Safari", pid: 10, playing: true), h.process("Spotify", pid: 11, playing: true),
    ])
    await h.settle()
    h.access.answer = .granted
    await h.store.checkSilentTap()
    h.access.answer = .denied  // revoked right after
    await h.store.checkSilentTap(mayReuseRecentGrant: true)
    await h.settle()
    #expect(h.access.requests == 1, "a repeat of a checked silence reuses the grant")
    #expect(h.controller.reconcileCalls.last?.count == 2, "both taps kept")
  }

  /// S41R-M1 (fixed): the first silence after real sound never uses the cached grant, so a
  /// revocation right after a check is found at once.
  @Test func aFreshSilenceIgnoresTheCachedGrant() async {
    let h = MixerHarness(permission: .granted)
    h.start([
      h.process("Safari", pid: 10, playing: true), h.process("Spotify", pid: 11, playing: true),
    ])
    await h.settle()
    h.access.answer = .granted
    await h.store.checkSilentTap()
    h.access.answer = .denied  // revoked right after
    await h.store.checkSilentTap()  // first silence after sound
    await h.settle()
    #expect(h.access.requests == 2, "a real test tap ran")
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "no app stays mute")
  }

  /// SPEC 4.6: after the silence guard's ambiguous denial, with nothing playing, the popover
  /// does not show the permission notice; when something plays again the permission is
  /// checked at once.
  @Test func ambiguousDenialShowsNoNoticeWhileNothingPlaysAndRechecksWhenSoundReturns() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Safari", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    #expect(h.store.showsPermissionNotice, "something still plays: the notice is shown")
    h.start([h.process("Safari", pid: 10, playing: false)])
    #expect(h.permission.isDenied)
    #expect(!h.store.showsPermissionNotice, "nothing plays: no notice")
    h.access.answer = .granted
    h.start([h.process("Safari", pid: 10, playing: true)])
    #expect(await eventually { h.permission.status == .granted })
    #expect(h.access.requests == 2, "checked as soon as something plays again")
    #expect(!h.store.showsPermissionNotice)
  }
}
