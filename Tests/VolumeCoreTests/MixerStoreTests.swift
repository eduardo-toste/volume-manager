import Testing

@testable import VolumeCore

@MainActor
@Suite("MixerStore", .timeLimit(.minutes(1)))
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
    #expect(h.store.rows.map(\.app.name) == ["Safari", "Spotify"], "idle apps are not listed")
    h.store.handle(
      .processes([
        h.process("Zoom", pid: 1, playing: false, inCall: true),
        h.process("Spotify", pid: 2, playing: false), h.process("Safari", pid: 3, playing: true),
        h.process("Música", pid: 4, playing: true),
      ]))
    // Zoom in a call counts as playing for the order; Spotify stopped just now.
    #expect(h.store.rows.map(\.app.name) == ["Música", "Safari", "Spotify", "Zoom"])
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
    h.start([
      h.process("Spotify", pid: 1, playing: true),
      h.process("Safari", pid: 2, playing: true),
      h.process("Zoom", pid: 3, playing: false, inCall: true),
    ])
    #expect(h.store.rows.count == 3)
    #expect(h.store.playingCount == 2)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(h.store.playingCount == 0)
  }

  // MARK: Playing or in a call (SPEC 3.2 item 4, 4.1)

  @Test func idleAppsAreNotListed() {
    h.start([h.process("Spotify", pid: 1, playing: false)])
    #expect(h.store.rows.isEmpty)
  }

  @Test func appThatStoppedLeavesAfterThreeSeconds() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 }, "list grace and tap linger")
    h.clock.advance(by: MixerStore.listGracePeriod - .milliseconds(1))
    await Task.yield()
    #expect(h.store.rows.count == 1, "still listed at 2.999 s")
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.store.rows.isEmpty }, "gone at 3 s")
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1, "the tap keeps its own 15 s")
  }

  @Test func trackChangeShorterThanThreeSecondsNeverBlinks() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    for _ in 0..<5 {
      h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
      #expect(h.store.rows.count == 1)
      #expect(await eventually { h.clock.sleeperCount >= 1 })
      h.clock.advance(by: .seconds(2))
      await Task.yield()
      #expect(h.store.rows.count == 1)
      h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
      #expect(h.store.rows.count == 1)
    }
  }

  /// A volume set on an app does not keep its row (SPEC 3.2): it leaves 3 s after stopping, and
  /// the volume applies again when it plays.
  @Test func adjustedAppLeavesAfterThreeSecondsAndItsVolumeReturns() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount >= 2 })
    h.clock.advance(by: MixerStore.listGracePeriod)
    #expect(await eventually { h.store.rows.isEmpty })
    h.clock.advance(by: MixerStore.tapLingerPeriod)
    #expect(await eventually { h.controller.reconcileCalls.last?.isEmpty == true })
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(h.store.rows.first?.state.volume == 0.4)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.first?.gain == VolumeCurve.gain(forVolume: 0.4))
  }

  /// Discord in a call with its output off (nobody talks): listed for as long as the call
  /// lasts, and never tapped.
  @Test func appInACallWithOutputOffStaysListedWithoutATap() async {
    h.start([h.process("Zoom", pid: 1, playing: false, inCall: true)])
    for _ in 0..<10 {
      h.clock.advance(by: .seconds(60))
      await Task.yield()
      #expect(h.store.rows.map(\.app.name) == ["Zoom"])
    }
    await h.settle()
    #expect(h.controller.neverTapped, "in a call but not playing: no tap")
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false, inCall: false)]))
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.listGracePeriod - .milliseconds(1))
    await Task.yield()
    #expect(h.store.rows.count == 1, "the call ended 2.999 s ago")
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.store.rows.isEmpty }, "microphone off: gone in 3 s")
  }

  /// In a call, the output goes on and off as people talk: the row never blinks.
  @Test func callWithOutputOnAndOffNeverBlinks() async {
    h.start([h.process("Zoom", pid: 1, playing: true, inCall: true)])
    var playing = true
    for step in 0..<40 {
      playing.toggle()
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: playing, inCall: true)]))
      h.clock.advance(by: .seconds([1, 3, 2][step % 3]))
      await Task.yield()
      #expect(h.store.rows.map(\.app.name) == ["Zoom"])
    }
  }

  /// An app in a call that stopped playing less than 15 s ago keeps its place; the order is
  /// "playing first", with a recent stop counted as playing (SPEC 4.1).
  @Test func recentlyStoppedAppKeepsItsPlaceUntilTheLingerEnds() async {
    h.start([
      h.process("Safari", pid: 1, playing: true),
      h.process("Zoom", pid: 2, playing: true),
    ])
    #expect(h.store.rows.map(\.app.name) == ["Safari", "Zoom"])
    h.store.handle(
      .processes([
        h.process("Safari", pid: 1, playing: false), h.process("Zoom", pid: 2, playing: true),
      ]))
    #expect(h.store.rows.map(\.app.name) == ["Safari", "Zoom"], "Safari stopped just now")
    #expect(h.store.playingCount == 1)
  }

  // MARK: Live list without notifications (SPEC 4.1 safety nets)

  /// The popover is open, there is no tap and the per-process notification never comes: the
  /// 1 s re-reading finds the stop, and the row goes within 3 s + 1 s.
  @Test func openPopoverFindsAStopWithoutNotification() async {
    h.system.refreshPublishes = true
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.popoverOpened()
    // Spotify stops, but Core Audio says nothing: only the snapshot knows.
    h.system.setSnapshot(
      AudioSystemSnapshot(processes: [h.process("Spotify", pid: 1, playing: false)]))
    let task = Task { await h.store.run() }
    #expect(await eventually { h.system.subscriberCount == 1 })
    h.system.setSnapshot(
      AudioSystemSnapshot(processes: [h.process("Spotify", pid: 1, playing: true)]))
    #expect(await eventually { h.store.rows.count == 1 })
    h.system.setSnapshot(
      AudioSystemSnapshot(processes: [h.process("Spotify", pid: 1, playing: false)]))
    var elapsed: Duration = .zero
    while !h.store.rows.isEmpty && elapsed < .seconds(10) {
      #expect(await eventually { h.clock.sleeperCount >= 1 })
      h.clock.advance(by: .milliseconds(500))
      elapsed += .milliseconds(500)
      for _ in 0..<50 { await Task.yield() }
      await h.settle()
    }
    #expect(h.store.rows.isEmpty)
    #expect(elapsed <= MixerStore.listGracePeriod + MixerStore.openRefreshInterval)
    h.store.popoverClosed()
    h.system.finish()
    await task.value
  }

  /// With a tap, the watchdog sees the stop (`.stoppedPlaying`, within one 0.5 s tick, see
  /// `M53WatchdogTests`) and the composition re-reads the system: the row then goes in 3 s,
  /// with no per-process notification.
  @Test func watchdogStopReReadsAndTheRowGoesInThreeSeconds() async {
    h.system.refreshPublishes = true
    h.system.setSnapshot(
      AudioSystemSnapshot(processes: [h.process("Spotify", pid: 1, playing: true)]))
    let task = Task { await h.store.run() }
    #expect(await eventually { h.store.rows.count == 1 })
    h.system.setSnapshot(
      AudioSystemSnapshot(processes: [h.process("Spotify", pid: 1, playing: false)]))
    h.store.refreshAudioSystem()  // what `.stoppedPlaying` does (Composition)
    #expect(await eventually { h.store.playingCount == 0 })
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.listGracePeriod)
    #expect(await eventually { h.store.rows.isEmpty })
    h.system.finish()
    await task.value
  }

  /// The 1 s re-reading exists only while the popover is open.
  @Test func openRefreshRunsOnlyWhileThePopoverIsOpen() async {
    h.start([])
    await h.settle()
    #expect(h.clock.sleeperCount == 0, "closed: no timer")
    h.store.popoverOpened()
    #expect(await eventually { h.clock.sleeperCount == 1 })
    let before = h.system.calls.filter { $0 == .refresh }.count
    for _ in 0..<3 {
      h.clock.advance(by: MixerStore.openRefreshInterval)
      #expect(await eventually { h.clock.sleeperCount == 1 })
    }
    await h.settle()
    #expect(h.system.calls.filter { $0 == .refresh }.count == before + 3, "one re-read a second")
    h.store.popoverClosed()
    #expect(await eventually { h.clock.sleeperCount == 0 }, "closed: the timer stops")
    h.clock.advance(by: .seconds(10))
    await h.settle()
    #expect(h.system.calls.filter { $0 == .refresh }.count == before + 3)
  }

  @Test func appThatLeavesTheProcessListLeavesImmediatelyAndItsTimerStops() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })
    h.store.handle(.processes([]))
    #expect(h.store.rows.isEmpty)
    #expect(await eventually { h.clock.sleeperCount == 0 })
  }

  // MARK: Always controlled while playing (SPEC 4.2)

  @Test func untouchedPlayingAppsGetAnUnchangedTap() async {
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: false),
    ])
    await h.settle()
    let sent = h.controller.reconcileCalls.last ?? []
    #expect(sent.map(\.app.id) == [spotify], "only the app that plays")
    #expect(SpyAppAudioController.isUnchanged(sent))
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

  @Test func fullVolumeKeepsTheTapAtUnityGain() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: spotify)
    h.store.setVolume(1.0, for: spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    #expect(h.controller.reconcileCalls.last?.first?.gain == 1)
    #expect(h.controller.reconcileCalls.last?.first?.muted == false)
  }

  // MARK: Round 5: always controlled while playing (SPEC 4.2)

  @Test func appThatStartsPlayingGetsOneUnchangedTap() async {
    h.start([h.process("Spotify", pid: 1, playing: false)])
    await h.settle()
    #expect(h.controller.neverTapped, "no IO for an app that is not playing")
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    let sent = h.controller.reconcileCalls.last ?? []
    #expect(sent.count == 1)
    #expect(sent.first?.gain == 1)
    #expect(SpyAppAudioController.isUnchanged(sent))
  }

  @Test func tapStaysThroughAShortPauseAndGoesAfterTheLingerPeriod() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: spotify)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 3 })  // grace, linger, saved volume
    h.clock.advance(by: .seconds(10))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.allSatisfy { $0.count == 1 }, "the same tap all along")
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })  // grace and linger timers
    h.clock.advance(by: MixerStore.tapLingerPeriod - .milliseconds(1))
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.controller.reconcileCalls.last?.isEmpty == true })
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(h.store.rows.first?.state.volume == 0.4, "the volume is kept for the next play")
  }

  @Test func withoutTheConfirmedPermissionNoAppIsTapped() async {
    let waiting = MixerHarness(permission: .notDetermined)
    waiting.start([
      waiting.process("Spotify", pid: 1, playing: true),
      waiting.process("Safari", pid: 2, playing: true),
    ])
    await waiting.settle()
    #expect(waiting.controller.neverTapped)
    #expect(waiting.access.requests == 0, "the system prompt only after a user action")
  }

  @Test func restoreRemovesEveryTapAtOnceAndKeepsThemOffUntilTheUserActs() async {
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
    ])
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 2)
    h.store.restoreOriginalAudio()
    h.store.handle(
      .processes([
        h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
        h.process("Zoom", pid: 3, playing: true),
      ]))
    await h.settle()
    #expect(h.controller.restoreAllCount == 1)
    #expect(h.controller.reconcileCalls.last?.isEmpty == true)
    h.store.setVolume(0.5, for: spotify)
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 3)
  }

  // MARK: Round 5b: silent taps (SPEC 4.6)

  private func twoTappedApps() async -> MixerHarness {
    let tapped = MixerHarness(permission: .granted)
    tapped.start([
      tapped.process("Spotify", pid: 1, playing: true),
      tapped.process("Safari", pid: 2, playing: true),
    ])
    await tapped.settle()
    #expect(tapped.controller.reconcileCalls.last?.count == 2)
    return tapped
  }

  /// Revoked permission: every tap goes at once (no app stays mute) and the popover says so;
  /// the denial is ambiguous, so it is not stored, and a later check brings the taps back.
  @Test func silenceWithTheRevokedPermissionRemovesEveryTapAtOnce() async {
    let h = await twoTappedApps()
    h.settings.audioPermissionConfirmed = true
    h.access.answer = .denied
    await h.store.checkSilentTap()
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "original sound for every app")
    #expect(h.permission.status == .denied, "the popover shows the no-permission state")
    #expect(h.settings.audioPermissionConfirmed, "an ambiguous denial is not stored")
    #expect(h.access.requests == 1)

    // Checked again by itself while something plays, at most every 30 s.
    h.access.answer = .granted
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.permissionRecheckInterval - .milliseconds(1))
    await h.settle()
    #expect(h.access.requests == 1)
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.access.requests == 2 })
    #expect(await eventually { h.permission.status == .granted })
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 2, "the taps are back")
  }

  @Test func legitimateSilenceKeepsEveryTapAndARecentGrantIsReused() async {
    let h = await twoTappedApps()
    h.access.answer = .granted
    let sent = h.controller.reconcileCalls.count
    await h.store.checkSilentTap()
    await h.store.checkSilentTap(mayReuseRecentGrant: true)
    await h.settle()
    #expect(h.controller.reconcileCalls.count == sent, "nothing changes")
    #expect(h.permission.status == .granted)
    #expect(h.access.requests == 1, "the repeated check reused the recent grant")
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.permissionRecheckInterval)
    for _ in 0..<50 { await Task.yield() }
    await h.store.checkSilentTap(mayReuseRecentGrant: true)
    #expect(h.access.requests == 2, "a grant older than 30 s is checked again")
  }

  @Test func inconclusiveCheckKeepsTheTaps() async {
    let h = await twoTappedApps()
    h.access.answer = .granted
    h.access.conclusive = false
    await h.store.checkSilentTap()
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 2)
    #expect(h.permission.status == .granted)
  }

  /// QA-2: with "always controlled", an output format that cannot be controlled must not flag
  /// an app the user never adjusted; once the user adjusts it, the warning shows.
  @Test func unsupportedFormatIsQuietUntilTheUserAdjustsTheApp() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.controlFailed(spotify, quietIfUntouched: true)
    #expect(h.store.failedAppIDs.isEmpty)
    h.store.setVolume(0.5, for: spotify)
    #expect(h.store.failedAppIDs == [spotify])
    h.store.toggleMute("com.apple.Safari")
    h.store.controlFailed(spotify, quietIfUntouched: true)
    #expect(h.store.failedAppIDs == [spotify], "an adjusted app shows the warning")
  }

  /// Round 4 (clicks): dragging through 100% never removes the tap. Every value of the drag
  /// keeps one entry, so the controller only moves the gain; the tap goes away only once the
  /// slider rests at 100%.
  @Test func draggingThroughFullVolumeNeverRemovesTheTap() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    for volume in [0.6, 0.8, 0.95, 1.0, 1.0, 0.9, 1.0, 0.7, 1.0, 0.85] {
      h.store.setVolume(volume, for: spotify)
      await h.settle()
    }
    let sent = h.controller.reconcileCalls
    #expect(!sent.isEmpty)
    #expect(sent.allSatisfy { $0.count == 1 }, "no list without the app during the drag")
    #expect(sent.last?.first?.gain ?? 1 < 1)
  }

  /// Round 4 (clicks): with the permission granted, volume and mute changes never run the
  /// signal check (which creates a test tap and stops it after 500 ms).
  @Test func volumeChangesWithThePermissionGrantedNeverRunTheAccessCheck() async {
    let granted = MixerHarness(permission: .granted)
    granted.start([granted.process("Spotify", pid: 1, playing: true)])
    for step in 1...20 {
      granted.store.setVolume(Double(step) / 40, for: spotify)
      if step.isMultiple(of: 5) { granted.store.toggleMute(spotify) }
    }
    await granted.settle()
    #expect(granted.access.requests == 0)
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
    #expect(SpyAppAudioController.isUnchanged(h.controller.reconcileCalls.last ?? []))
  }

  @Test func routingToTheDefaultDeviceChangesNothing() async {
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route(spotify, to: "speakers")
    await h.settle()
    #expect(h.controller.onlyUnchangedAudio)
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
    #expect(h.controller.onlyUnchangedAudio)
    #expect(h.controller.reconcileCalls.allSatisfy { $0.allSatisfy { $0.app.id == spotify } })
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
    #expect(SpyAppAudioController.isUnchanged(h.controller.reconcileCalls.last ?? []))
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
    #expect(h.controller.onlyUnchangedAudio)
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

  /// Bug of the ⏸2 retest: apps that were already playing when the Volume started must be
  /// listed from the first snapshot, before any change event arrives.
  @Test func appsAlreadyPlayingAtLaunchAreListedWithoutAnyEvent() async {
    h.system.setSnapshot(
      AudioSystemSnapshot(
        processes: [
          h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
          h.process("Safari", pid: 3, playing: false), h.process("Zoom", pid: 4, playing: false),
        ],
        devices: [MixerHarness.speakers], defaultOutputUID: "speakers"))
    let store = h.store
    let task = Task { await store.run() }
    #expect(await eventually { h.system.subscriberCount == 1 && !store.rows.isEmpty })
    #expect(store.rows.map(\.app.name) == ["Safari", "Spotify"], "idle untouched Zoom hidden")
    #expect(store.playingCount == 2)
    #expect(store.rows.first { $0.app.name == "Safari" }?.app.pids == [2, 3])
    store.refreshAudioSystem()
    #expect(await eventually { h.system.calls.contains(.refresh) })
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
