import Testing

@testable import VolumeCore

@MainActor
@Suite("MixerStore")
struct MixerStoreTests {
  let h = MixerHarness()

  private var spotify: String { "com.spotify.client" }

  // MARK: List and counter

  @Test func playingAppsComeFirstThenByName() {
    h.start([
      h.process("Zoom", pid: 1, playing: false),
      h.process("Spotify", pid: 2, playing: true),
      h.process("Safari", pid: 3, playing: true),
      h.process("Música", pid: 4, playing: false),
    ])
    h.settings.showInactiveApps = true
    #expect(h.store.rows.map(\.app.name) == ["Safari", "Spotify", "Música", "Zoom"])
  }

  @Test func orderingUsesLocalizedNames() {
    h.info.setApp("/Applications/App10.app", name: "App 10", bundleID: "com.a.App10")
    h.info.setApp("/Applications/App2.app", name: "App 2", bundleID: "com.a.App2")
    h.start([
      AudioProcessInfo(
        pid: 1, executablePath: "/Applications/App10.app/Contents/MacOS/x", isRunningOutput: true),
      AudioProcessInfo(
        pid: 2, executablePath: "/Applications/App2.app/Contents/MacOS/x", isRunningOutput: true),
    ])
    #expect(h.store.rows.map(\.app.name) == ["App 2", "App 10"])
  }

  @Test func sameNameIsOrderedByID() {
    h.info.setApp("/Applications/A1.app", name: "Same", bundleID: "com.a.one")
    h.info.setApp("/Applications/A2.app", name: "Same", bundleID: "com.a.two")
    h.start([
      AudioProcessInfo(
        pid: 1, executablePath: "/Applications/A2.app/Contents/MacOS/x", isRunningOutput: true),
      AudioProcessInfo(
        pid: 2, executablePath: "/Applications/A1.app/Contents/MacOS/x", isRunningOutput: true),
    ])
    #expect(h.store.rows.map(\.id) == ["com.a.one", "com.a.two"])
  }

  @Test func playingCounterCountsOnlyPlayingApps() {
    h.settings.showInactiveApps = true
    h.start([
      h.process("Spotify", pid: 1, playing: true),
      h.process("Safari", pid: 2, playing: true),
      h.process("Zoom", pid: 3, playing: false),
    ])
    #expect(h.store.rows.count == 3)
    #expect(h.store.playingCount == 2)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(h.store.playingCount == 0)
  }

  @Test func idleAppsAreHiddenByDefault() {
    h.start([h.process("Spotify", pid: 1, playing: false)])
    #expect(h.store.rows.isEmpty)
    h.settings.showInactiveApps = true
    #expect(h.store.rows.count == 1)
    h.settings.showInactiveApps = false
    #expect(h.store.rows.isEmpty)
  }

  // MARK: Five second delay

  @Test func appThatStoppedStaysFiveSecondsThenDisappears() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(h.store.rows.count == 1)
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: .milliseconds(4999))
    await Task.yield()
    #expect(h.store.rows.count == 1)
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.store.rows.isEmpty })
  }

  @Test func appThatResumesCancelsTheRemoval() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 1 })
    h.clock.advance(by: .seconds(3))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(await eventually { h.clock.sleeperCount == 0 })
    h.clock.advance(by: .seconds(10))
    await Task.yield()
    #expect(h.store.rows.count == 1)
  }

  @Test func nothingDisappearsWhileShowingInactiveApps() async {
    h.settings.showInactiveApps = true
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })
    h.clock.advance(by: .seconds(6))
    await Task.yield()
    await Task.yield()
    #expect(h.store.rows.count == 1)
  }

  @Test func appThatLeavesTheProcessListLeavesImmediatelyAndItsTimerStops() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 1 })
    h.store.handle(.processes([]))
    #expect(h.store.rows.isEmpty)
    #expect(await eventually { h.clock.sleeperCount == 0 })
  }

  // MARK: No tap at 100%

  @Test func untouchedAppsGetNoTap() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.controller.neverTapped)
  }

  @Test func changingVolumeCreatesDesiredStateWithCurveGain() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    let desired = h.controller.reconcileCalls.last
    #expect(desired?.count == 1)
    #expect(desired?.first?.gain == 0.25)
    #expect(desired?.first?.muted == false)
    #expect(desired?.first?.targetDeviceUID == "speakers")
    #expect(desired?.first?.app.pids == [1])
  }

  @Test func backTo100PercentRemovesTheEntry() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.setVolume(1.0, for: spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
  }

  @Test func muteCreatesAnEntryAndKeepsTheSliderValue() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.8, for: spotify)
    h.store.toggleMute(spotify)
    await h.settle()
    let entry = h.controller.reconcileCalls.last?.first
    #expect(entry?.muted == true)
    #expect(h.store.rows.first?.state.volume == 0.8)
    h.store.toggleMute(spotify)
    #expect(h.store.rows.first?.state.muted == false)
  }

  @Test func muteAt100PercentStillNeedsATap() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleMute(spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
  }

  @Test func routingToAnotherDeviceNeedsATapEvenAt100() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route(spotify, to: "airpods")
    await h.settle()
    let entry = h.controller.reconcileCalls.last?.first
    #expect(entry?.targetDeviceUID == "airpods")
    #expect(entry?.gain == 1)
    #expect(h.store.rows.first?.usesSystemDefault == false)
    #expect(h.store.rows.first?.device?.name == "AirPods Pro")
    h.store.route(spotify, to: nil)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
  }

  @Test func routingToTheDefaultDeviceNeedsNoTap() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route(spotify, to: "speakers")
    await h.settle()
    #expect(h.controller.neverTapped)
  }

  @Test func routingToUnknownDevicesIsIgnored() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route(spotify, to: "ghost")
    #expect(h.store.rows.first?.state.preferredOutputUID == nil)
  }

  @Test func hostileVolumesAreMadeSafe() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(.nan, for: spotify)
    #expect(h.store.rows.first?.state.volume == 1)
    h.store.setVolume(.infinity, for: spotify)
    #expect(h.store.rows.first?.state.volume == 1)
    h.store.setVolume(-5, for: spotify)
    #expect(h.store.rows.first?.state.volume == 0)
  }

  @Test func intentsForUnknownAppsAreIgnored() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.1, for: "com.ghost.App")
    h.store.toggleMute("com.ghost.App")
    h.store.route("com.ghost.App", to: "airpods")
    await h.settle()
    #expect(h.controller.neverTapped)
  }

  // MARK: Idempotence

  @Test func unchangedDesiredStateIsNotResent() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    let sent = h.controller.reconcileCalls.count
    h.store.setVolume(0.5, for: spotify)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    h.store.handle(.master(MasterOutputState(volume: 0.3, isMuted: false)))
    h.store.toggleExpanded(spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.count == sent)
  }

  @Test func newHelperProcessUpdatesTheTappedPIDs() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.handle(
      .processes([
        h.process("Spotify", pid: 1, playing: true), h.process("Spotify", pid: 9, playing: true),
      ]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.app.pids == [1, 9])
  }

  @Test func changingTheDefaultOutputUpdatesTappedAppsFollowingIt() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.handle(.defaultOutput(uid: "airpods"))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.targetDeviceUID == "airpods")
  }

  @Test func appsWithoutAKnownRouteAreLeftAlone() async {
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.controller.neverTapped)
  }

  @Test func tappedIdleAppKeepsItsTapWhileItIsInTheProcessList() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    h.store.handle(.processes([]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
  }

  // MARK: Fallback and restoration of routes

  @Test func routeFallsBackWhenTheDeviceDisconnectsAndComesBack() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route(spotify, to: "airpods")
    h.store.handle(.devices([MixerHarness.speakers]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
    #expect(h.store.rows.first?.savedDeviceMissing == true)
    #expect(h.store.rows.first?.device?.uid == "speakers")
    #expect(h.store.rows.first?.state.preferredOutputUID == "airpods")
    h.store.handle(.devices([MixerHarness.speakers, MixerHarness.airpods]))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.targetDeviceUID == "airpods")
    #expect(h.store.rows.first?.savedDeviceMissing == false)
  }

  // MARK: Remembering

  @Test func changesAreRememberedByBundleID() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    h.store.toggleMute(spotify)
    h.store.route(spotify, to: "airpods")
    #expect(
      h.settings.remembered(for: spotify)
        == RememberedApp(volume: 0.4, muted: true, outputUID: "airpods"))
  }

  @Test func backToDefaultsForgetsTheApp() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    h.store.setVolume(1, for: spotify)
    #expect(h.settings.remembered(for: spotify) == nil)
  }

  @Test func nothingIsRememberedWhenTheOptionIsOff() {
    h.settings.rememberVolumes = false
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    #expect(h.settings.rememberedApps.isEmpty)
  }

  @Test func rememberedStateIsAppliedWhenTheAppAppears() async {
    let h = MixerHarness(preferences: [
      "rememberedApps": [
        "com.spotify.client": ["volume": 0.3, "muted": true, "outputUID": "airpods"]
      ] as [String: Any]
    ])
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(
      h.store.rows.first?.state
        == AppAudioState(volume: 0.3, muted: true, preferredOutputUID: "airpods"))
    let entry = h.controller.reconcileCalls.last?.first
    #expect(entry?.muted == true)
    #expect(entry?.targetDeviceUID == "airpods")
  }

  @Test func rememberedStateIsIgnoredWhenTheOptionIsOff() {
    let h = MixerHarness(preferences: [
      "rememberVolumes": false,
      "rememberedApps": ["com.spotify.client": ["volume": 0.3, "muted": true]] as [String: Any],
    ])
    h.start([h.process("Spotify", pid: 1, playing: true)])
    #expect(h.store.rows.first?.state == .default)
  }

  @Test func rememberedStateIsIgnoredInSafeMode() async {
    let remembered: [String: Any] = [
      "rememberedApps": ["com.spotify.client": ["volume": 0.3, "muted": true]] as [String: Any]
    ]
    var preferences = remembered
    preferences["safety.sessionStarted"] = true
    preferences["safety.cleanExit"] = false
    preferences["safety.stable"] = false
    preferences["safety.earlyCrashes"] = 1
    let h = MixerHarness(preferences: preferences, beginSafety: true)
    #expect(h.store.isSafeMode)
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(h.store.rows.first?.state == .default)
    #expect(h.controller.neverTapped)
    #expect(h.settings.remembered(for: "com.spotify.client") != nil)
  }

  @Test func rememberedMuteIsNeverAppliedWithoutRememberOrInSafeMode() {
    let off = MixerHarness(preferences: [
      "rememberVolumes": false,
      "rememberedApps": ["com.spotify.client": ["muted": true]] as [String: Any],
    ])
    off.start([off.process("Spotify", pid: 1, playing: true)])
    #expect(off.store.rows.first?.state.muted == false)
  }

  @Test func sessionStateSurvivesTheAppDisappearingAndReturning() {
    h.settings.rememberVolumes = false
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    h.store.handle(.processes([]))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(h.store.rows.first?.state.volume == 0.4)
  }

  // MARK: Restore original audio

  @Test func restoreOriginalAudioResetsEverything() async {
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
    ])
    h.store.setVolume(0.2, for: spotify)
    h.store.toggleMute("com.apple.Safari")
    h.store.route(spotify, to: "airpods")
    await h.settle()
    h.store.restoreOriginalAudio()
    await h.settle()
    #expect(h.controller.restoreAllCount == 1)
    #expect(h.store.rows.map(\.state).allSatisfy { $0 == .default })
    #expect(h.settings.rememberedApps.isEmpty)
    let sent = h.controller.calls.count
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.calls.count == sent, "nothing is re-sent after the reset")
    #expect(h.controller.calls.suffix(2).contains(.reconcile([])))
  }

  @Test func appsCanBeControlledAgainAfterRestore() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.2, for: spotify)
    h.store.restoreOriginalAudio()
    h.store.setVolume(0.6, for: spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.gain == Float(0.6 * 0.6))
  }

  // MARK: Expansion

  @Test func onlyOneRowIsExpanded() {
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
    ])
    h.store.toggleExpanded(spotify)
    #expect(h.store.expandedAppID == spotify)
    h.store.toggleExpanded("com.apple.Safari")
    #expect(h.store.expandedAppID == "com.apple.Safari")
    h.store.toggleExpanded("com.apple.Safari")
    #expect(h.store.expandedAppID == nil)
  }

  @Test func expandedRowCollapsesWhenTheAppLeaves() {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleExpanded(spotify)
    h.store.handle(.processes([]))
    #expect(h.store.expandedAppID == nil)
  }

  // MARK: Master output and devices

  @Test func masterVolumeIsClampedAndSentToTheSystem() async {
    h.store.setMasterVolume(0.4)
    h.store.setMasterVolume(7)
    h.store.setMasterVolume(.nan)
    h.store.setMasterVolume(.infinity)
    await h.settle()
    #expect(h.system.calls == [.masterVolume(1)], "writes in a burst are coalesced")
    #expect(h.store.masterVolume == 1)
  }

  @Test func systemEchoesDoNotMoveTheSliderWhileWritesArePending() async {
    h.store.setMasterVolume(0.2)
    h.store.setMasterVolume(0.6)
    h.store.handle(.master(MasterOutputState(volume: 0.2, isMuted: false)))
    #expect(h.store.masterVolume == 0.6)
    await h.settle()
    h.store.handle(.master(MasterOutputState(volume: 0.6, isMuted: false)))
    #expect(h.store.masterVolume == 0.6)
    h.store.handle(.master(MasterOutputState(volume: 0.3, isMuted: false)))
    #expect(h.store.masterVolume == 0.3, "external changes are followed again after the writes")
  }

  @Test func appVolumeBurstsAreCoalescedAndTheLastValueWins() async {
    h.start([h.process("Spotify", pid: 10, playing: true)])
    await h.settle()
    let before = h.controller.reconcileCalls.count
    for step in 1...9 { h.store.setVolume(1 - Double(step) / 10, for: "com.spotify.client") }
    await h.settle()
    #expect(h.controller.reconcileCalls.count == before + 1)
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.1))
  }

  @Test func refreshAsksTheAudioSystemToReadAgain() async {
    h.store.refreshAudioSystem()
    await h.settle()
    #expect(h.system.calls == [.refresh])
  }

  @Test func aPlayingAppAppearsWithoutReopeningAnything() {
    h.start([])
    #expect(h.store.rows.isEmpty)
    h.store.handle(.processes([h.process("Spotify", pid: 10, playing: true)]))
    #expect(h.store.rows.map(\.app.name) == ["Spotify"])
  }

  @Test func masterMuteToggles() async {
    h.store.toggleMasterMute()
    h.store.toggleMasterMute()
    await h.settle()
    #expect(h.system.calls == [.masterMuted(true), .masterMuted(false)])
    #expect(!h.store.masterMuted)
  }

  @Test func defaultOutputCanOnlyBeSetToKnownDevices() async {
    h.start([])
    h.store.setDefaultOutput("ghost")
    h.store.setDefaultOutput("airpods")
    await h.settle()
    #expect(h.system.calls == [.defaultOutput("airpods")])
    #expect(
      h.store.defaultOutput?.uid == "speakers", "state follows the system event, not the intent")
  }

  @Test func externalMasterChangesAreReflected() {
    h.store.handle(.master(MasterOutputState(volume: 0.25, isMuted: true)))
    #expect(h.store.masterVolume == 0.25)
    #expect(h.store.masterMuted)
  }

  @Test func masterSliderIsDisabledForDevicesWithoutVolume() {
    let dac = OutputDevice(id: 9, uid: "dac", name: "USB DAC", kind: .usb, hasVolumeControl: false)
    #expect(h.store.masterHasVolumeControl)
    h.store.handle(.devices([dac, MixerHarness.speakers]))
    h.store.handle(.defaultOutput(uid: "dac"))
    #expect(!h.store.masterHasVolumeControl)
    h.store.handle(.defaultOutput(uid: "speakers"))
    #expect(h.store.masterHasVolumeControl)
  }

  @Test func deviceListIsDeduplicatedByUID() {
    h.store.handle(
      .devices([
        MixerHarness.speakers, OutputDevice(id: 5, uid: "speakers", name: "Dup"),
        OutputDevice(id: 6, uid: "", name: "No UID"),
      ]))
    #expect(h.store.devices.map(\.id) == [1])
  }

  @Test func defaultOutputUIDIsSanitized() {
    h.store.handle(.defaultOutput(uid: "a\u{202E}b"))
    #expect(h.store.defaultOutputUID == "ab")
    h.store.handle(.defaultOutput(uid: "\u{0007}"))
    #expect(h.store.defaultOutputUID == nil)
    h.store.handle(.defaultOutput(uid: nil))
    #expect(h.store.defaultOutputUID == nil)
  }

  // MARK: run()

  @Test func runLoadsTheSnapshotAndFollowsEvents() async {
    h.system.setSnapshot(
      AudioSystemSnapshot(
        processes: [h.process("Spotify", pid: 1, playing: true)],
        devices: [MixerHarness.speakers, MixerHarness.airpods], defaultOutputUID: "speakers",
        master: MasterOutputState(volume: 0.6, isMuted: false)))
    let store = h.store
    let task = Task { await store.run() }
    #expect(await eventually { store.rows.count == 1 && h.system.subscriberCount == 1 })
    #expect(store.masterVolume == 0.6)
    #expect(store.defaultOutput?.name == "Alto-falantes")
    h.system.emit(
      .processes([
        h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
      ]))
    #expect(await eventually { store.rows.count == 2 })
    h.system.finish()
    await task.value
  }

  @Test func runWithoutMasterStateKeepsDefaults() async {
    let store = h.store
    let task = Task { await store.run() }
    #expect(await eventually { h.system.subscriberCount == 1 })
    h.system.finish()
    await task.value
    #expect(store.masterVolume == 1)
  }

  @Test func restoreDiscardsPendingReconcilesAndForgetsEverything() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.restoreOriginalAudio()
    await h.settle()
    #expect(h.controller.neverTapped)
    #expect(h.controller.restoreAllCount == 1)
    #expect(h.settings.rememberedApps.isEmpty)
  }

  @Test func ownProcessAndItsHelpersAreExcludedByPID() {
    let own = MixerHarness()
    let store = MixerStore(
      audioSystem: own.system, controller: own.controller, appInfo: own.info,
      settings: own.settings, safety: own.safety, clock: own.clock, permission: grantedPermission(),
      ownPID: 42)
    store.handle(.devices([MixerHarness.speakers]))
    store.handle(
      .processes([
        AudioProcessInfo(pid: 42, bundleID: "com.x.Y", isRunningOutput: true),
        AudioProcessInfo(pid: 43, bundleID: "com.x.Y", responsiblePID: 42, isRunningOutput: true),
      ]))
    store.handle(
      .processes([AudioProcessInfo(pid: 44, bundleID: "com.x.Z", isRunningOutput: true)]))
    #expect(store.rows.map(\.id) == ["com.x.Z"])
  }
}
