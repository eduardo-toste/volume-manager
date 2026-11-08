import Testing

@testable import VolumeCore

/// Security audit M4.1: consequences in the domain of a false "denied" from the silence check
/// (a browser with an open silent stream is the only thing playing). They pass today and
/// document the behaviour the audit report classifies.
@MainActor
@Suite("Security M4.1: false denied after silence")
struct SecurityM41StoreTests {
  private let safari = "com.apple.Safari"

  /// S41-M1: a muted app loses its tap (fail open: it becomes audible) and the popover shows
  /// "no permission", although the permission was granted all along.
  @Test func falseDeniedUnmutesAMutedAppAndShowsNoPermission() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Safari", pid: 10, playing: true)])
    h.store.toggleMute(safari)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.muted == true)

    // The real probe answers denied for "only zeros while the process plays".
    h.access.answer = .denied
    #expect(await h.store.checkSilentTap())
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "muted app is no longer tapped")
    #expect(h.permission.isDenied)

    // Opening the popover re-checks; while the browser is still the only (silent) player the
    // answer is the same, so the state stays until something else plays.
    await h.permission.refresh(onlyIfDenied: true)
    #expect(h.permission.isDenied)
    #expect(h.store.rows.first?.state.muted == true, "the row still says muted")
  }
}
