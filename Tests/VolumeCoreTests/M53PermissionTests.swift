import Testing

@testable import VolumeCore

/// M5.3 (SPEC 3.2, 4.6, 5): the "no permission" notice only when the permission was proven
/// not given; the silence guard's "denied" fails open without changing the popover; the
/// automatic budget does not reset in the denied → granted cycle; the list is stable.
@MainActor
@Suite("M5.3: permission notice and silence guard", .timeLimit(.minutes(1)))
struct M53PermissionTests {
  private let marked: [String: Any] = ["audioPermissionConfirmed": true]

  /// The bug of the user's Discord call: nobody talks, the guard's check hears only zeros.
  /// Every tap goes (original sound returns), but the list stays, no notice, the mark stays.
  @Test func silenceGuardDenialFailsOpenSilently() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([
      h.process("Zoom", pid: 1, playing: true), h.process("Safari", pid: 2, playing: false),
    ])
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.count == 1)
    h.access.answer = .denied
    await h.store.checkSilentTap()
    await h.settle()
    #expect(h.controller.reconcileCalls.last?.isEmpty == true, "fail open: every tap destroyed")
    #expect(!h.store.showsPermissionNotice)
    #expect(h.store.rows.map(\.app.name) == ["Zoom", "Safari"], "the list stays")
    #expect(h.settings.audioPermissionConfirmed, "the mark stays")
    #expect(h.store.failedAppIDs.isEmpty, "no warning on the rows")
  }

  /// The endless cycle of the logs: guard "denied" → automatic "granted" → taps back → guard
  /// "denied" again… A "granted" right after the guard's denial no longer resets the budget,
  /// so the automatic checks stop after `maxDeniedRechecks` in all.
  @Test func deniedThenGrantedCycleDoesNotResetTheBudget() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    var automatic = 0
    for _ in 0..<(MixerStore.maxDeniedRechecks + 2) {
      h.access.answer = .denied
      await h.store.checkSilentTap()  // the guard (not budgeted)
      let before = h.access.requests
      h.access.answer = .granted
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false)]))
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: true)]))  // sound returns
      if automatic < MixerStore.maxDeniedRechecks {
        #expect(await eventually { h.access.requests > before })
      }
      for _ in 0..<50 { await Task.yield() }
      await h.settle()
      automatic += h.access.requests - before
    }
    #expect(automatic == MixerStore.maxDeniedRechecks, "budget spent once, never reset")
    #expect(h.permission.status == .denied, "after the budget the taps stay off (fail open)")
    #expect(!h.store.showsPermissionNotice)
    #expect(h.settings.audioPermissionConfirmed)
  }

  /// A "granted" asked for by the user (adjusting an app) gives the budget back.
  @Test func aGrantFromTheUserResetsTheBudget() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    for _ in 0..<MixerStore.maxDeniedRechecks {
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false)]))
      let before = h.access.requests
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: true)]))
      _ = await eventually { h.access.requests > before }
    }
    await h.settle()
    h.access.answer = .granted
    h.store.setVolume(0.5, for: "us.zoom.xos")
    await h.settle()
    #expect(h.permission.status == .granted)
    h.access.answer = .denied
    await h.store.checkSilentTap()
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false)]))
    let before = h.access.requests
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: true)]))
    #expect(await eventually { h.access.requests == before + 1 }, "automatic checks again")
  }

  /// SPEC 3.2 case 1: never confirmed on this Mac and "Permitir…" not clicked: the notice.
  @Test func neverConfirmedShowsTheNoticeUntilAllowIsClicked() async {
    let h = MixerHarness(permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: false)])
    #expect(h.store.showsPermissionNotice)
    h.access.conclusive = false  // nothing plays: inconclusive
    h.store.allowAccess()
    await h.settle()
    #expect(h.access.userActions == [true], "the check that shows the system prompt")
    #expect(!h.store.showsPermissionNotice, "inconclusive after the click hides the notice")
    #expect(!h.settings.audioPermissionConfirmed)
  }

  /// The user's print of 2026-11-10: "Permitir…" clicked, permission given in macOS, nothing
  /// playing. The notice goes away and stays away; the check runs when something plays, and
  /// its "granted" stores the mark.
  @Test func inconclusiveAllowChecksByItselfWhenSomethingPlays() async {
    let h = MixerHarness(permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: false)])
    h.access.conclusive = false
    h.store.allowAccess()
    await h.settle()
    h.store.popoverOpened()
    await h.settle()
    #expect(!h.store.showsPermissionNotice, "reopening with nothing playing: still hidden")
    h.access.conclusive = true
    h.access.answer = .granted
    let before = h.access.requests
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: true)]))
    #expect(await eventually { h.access.requests == before + 1 })
    await h.settle()
    #expect(h.settings.audioPermissionConfirmed)
    #expect(h.permission.status == .granted)
    #expect(h.controller.reconcileCalls.last?.count == 1, "the tap comes")
  }

  /// SPEC 3.2: the follow-up of "Permitir…" that concludes "denied" shows the notice again.
  @Test func followUpDenialShowsTheNoticeAgain() async {
    let h = MixerHarness(permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: false)])
    h.access.conclusive = false
    h.store.allowAccess()
    await h.settle()
    h.access.conclusive = true
    h.access.answer = .denied
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: true)]))
    #expect(await eventually { h.store.showsPermissionNotice })
    #expect(h.controller.neverTapped)
  }

  /// SPEC 3.2 case 3 and SPEC 5: a "denied" from "Permitir…" shows the notice and clears the
  /// mark; the next click opens System Settings and hides the notice until a check concludes.
  @Test func allowDeniedShowsTheNoticeThenOpensSystemSettings() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    h.access.answer = .denied
    _ = await h.store.requestAccess()
    #expect(h.store.showsPermissionNotice)
    #expect(!h.settings.audioPermissionConfirmed)
    let requests = h.access.requests
    h.store.allowAccess()
    await h.settle()
    #expect(h.access.opened == 1, "System Settings opened")
    #expect(h.access.requests == requests, "no check while the user is in System Settings")
    #expect(!h.store.showsPermissionNotice)
    h.access.answer = .granted
    h.store.popoverOpened()  // back from System Settings, something plays
    await h.settle()
    #expect(h.permission.status == .granted)
    #expect(h.settings.audioPermissionConfirmed)
    #expect(!h.store.showsPermissionNotice)
  }

  /// SPEC 3.2 case 2: without the mark, a "denied" that is not the guard's shows the notice.
  @Test func deniedWithoutTheMarkFromAnAdjustmentShowsTheNotice() async {
    let h = MixerHarness(permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    h.access.conclusive = false
    _ = await h.store.requestAccess()  // inconclusive click: hidden
    #expect(!h.store.showsPermissionNotice)
    h.access.conclusive = true
    h.access.answer = .denied
    h.store.setVolume(0.5, for: "us.zoom.xos")
    await h.settle()
    #expect(await eventually { h.store.showsPermissionNotice })
  }

  /// With the mark, checks nobody asked for never show the notice nor clear the mark, also
  /// when the popover opens on a silent stream.
  @Test func popoverOpenDenialWithTheMarkChangesNothing() async {
    let h = MixerHarness(preferences: marked, permission: .denied)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    h.access.answer = .denied
    h.store.popoverOpened()
    await h.settle()
    #expect(h.access.requests >= 1)
    #expect(!h.store.showsPermissionNotice)
    #expect(h.settings.audioPermissionConfirmed)
    #expect(h.store.rows.count == 1)
  }

  /// A call that switches its output on and off every 1 to 3 s for 60 s: the row is always
  /// listed and the desired audio always holds the app, so the tap is never rebuilt.
  @Test func onAndOffEverySecondsKeepsTheRowAndTheTap() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    var elapsed: Duration = .zero
    var playing = true
    var step = 0
    while elapsed < .seconds(60) {
      let length: Duration = .seconds([1, 3, 2][step % 3])
      _ = await eventually { h.clock.sleeperCount >= (playing ? 0 : 1) }
      h.clock.advance(by: length)
      elapsed += length
      playing.toggle()
      step += 1
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: playing)]))
      await h.settle()
      #expect(h.store.rows.map(\.app.name) == ["Zoom"])
    }
    #expect(h.controller.reconcileCalls.allSatisfy { $0.count == 1 }, "never without the tap")
    #expect(h.access.requests == 0, "no permission check")
  }
}
