import Testing

@testable import VolumeCore

/// QA M4.1: coalesced writes (master volume and reconcile) never lose the last value and keep
/// the order retry -> reconcile.
@MainActor
@Suite("QA M4.1: coalescing")
struct QAM41Tests {
  private let spotify = "com.spotify.client"

  @Test func masterWriterRestartsAfterItEnds() async {
    let h = MixerHarness()
    h.store.setMasterVolume(0.3)
    await h.settle()
    h.store.setMasterVolume(0.5)
    await h.settle()
    h.store.setMasterVolume(0.5)
    await h.settle()
    #expect(h.system.calls == [.masterVolume(0.3), .masterVolume(0.5), .masterVolume(0.5)])
  }

  @Test func masterLastValueAlwaysReachesTheSystemAfterAnyBurst() async {
    let h = MixerHarness()
    for round in 0..<20 {
      let values = (0...round % 7).map { Double($0 + round) / 40 }
      for value in values { h.store.setMasterVolume(value) }
      await h.settle()
      guard case .masterVolume(let last)? = h.system.calls.last else {
        Issue.record("no write")
        return
      }
      #expect(last == VolumeCurve.clampedVolume(values.last ?? 0))
    }
  }

  @Test func echoesAreFollowedAgainAfterTheLastWriteEnded() async {
    let h = MixerHarness()
    h.store.setMasterVolume(0.8)
    await h.settle()
    h.store.handle(.master(MasterOutputState(volume: 0.8, isMuted: true)))
    #expect(h.store.masterVolume == 0.8)
    #expect(h.store.masterMuted, "mute is never ignored")
  }

  @Test func retryRunsBeforeTheReconcileThatFollowsIt() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    h.store.controlFailed(spotify)
    h.store.setVolume(0.4, for: spotify)
    h.store.setVolume(0.3, for: spotify)
    await h.settle()
    let calls = h.controller.calls
    let retryIndex = calls.firstIndex(of: .retry(spotify))
    let lastReconcile = calls.lastIndex { if case .reconcile = $0 { true } else { false } }
    #expect(retryIndex != nil)
    #expect(retryIndex.flatMap { r in lastReconcile.map { r < $0 } } == true)
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.3))
  }

  @Test func retryAllTwiceStillEndsWithTheNewestDesiredAudio() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 10, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    h.store.retryAll()
    h.store.retryAll()
    h.store.setVolume(0.2, for: spotify)
    h.store.retryAll()
    await h.settle()
    let calls = h.controller.calls
    #expect(calls.filter { $0 == .retryAll }.count == 3)
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.2))
    if case .retryAll? = calls.last { Issue.record("a retry came after the last reconcile") }
  }

  @Test func burstWhileNotGrantedNeverTaps() async {
    let h = MixerHarness(permission: .denied)
    h.start([h.process("Spotify", pid: 10, playing: true)])
    for step in 1...5 { h.store.setVolume(Double(step) / 10, for: spotify) }
    await h.settle()
    #expect(h.controller.neverTapped)
  }
}

/// QA M4.1 round 5: "always controlled" must not hide an app without a tap behind an empty
/// "unchanged" check, and the panic / revoked paths stay off.
@MainActor
@Suite("QA M4.1: always controlled")
struct QAM41AlwaysControlledTests {
  private let spotify = "com.spotify.client"

  @Test func routeBackToDefaultAndDeviceRemovalKeepExactlyOneUnchangedEntry() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 10, playing: true)])
    h.store.route(spotify, to: "airpods")
    h.store.route(spotify, to: nil)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    #expect(SpyAppAudioController.isUnchanged(h.controller.reconcileCalls.last ?? []))
    h.store.route(spotify, to: "airpods")
    h.store.handle(.devices([MixerHarness.speakers]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    #expect(SpyAppAudioController.isUnchanged(h.controller.reconcileCalls.last ?? []))
  }

  @Test func restoreDuringTheLingerPeriodIsNotUndoneWhenTheTimerExpires() async {
    let h = MixerHarness()
    h.settings.showInactiveApps = true
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    h.store.handle(.processes([h.process("Spotify", pid: 10, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount >= 2 })
    h.store.restoreOriginalAudio()
    await h.settle()
    let calls = h.controller.calls.count
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
    h.clock.advance(by: MixerStore.tapLingerPeriod)
    await h.settle()
    h.store.handle(.processes([h.process("Spotify", pid: 10, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "still suspended")
    #expect(h.controller.restoreAllCount == 1)
    #expect(h.controller.calls.count >= calls)
  }

  @Test func afterADeniedSilenceCheckNewPlayingAppsGetNoTap() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .denied
    #expect(await h.store.checkSilentTap())
    h.store.handle(
      .processes([
        h.process("Spotify", pid: 10, playing: true), h.process("Zoom", pid: 11, playing: true),
      ]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
  }

  @Test func repeatedInconclusiveChecksNeverChangeTheTaps() async {
    let h = MixerHarness(permission: .granted)
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    h.access.answer = .granted
    h.access.conclusive = false
    let before = h.controller.reconcileCalls.count
    for _ in 0..<5 { #expect(await h.store.checkSilentTap() == false) }
    await h.settle()
    #expect(h.controller.reconcileCalls.count == before)
    #expect(h.permission.status == .granted)
  }
}
