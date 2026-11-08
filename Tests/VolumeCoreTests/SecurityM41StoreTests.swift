import Testing

@testable import VolumeCore

/// Security audit M4.1, round 6: a "denied" from the silence check is ambiguous (a browser with
/// an open silent stream may be the only player). The fix keeps the fail-open behaviour and
/// removes the lasting harm.
@MainActor
@Suite("Security M4.1: ambiguous denied after silence")
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
}
