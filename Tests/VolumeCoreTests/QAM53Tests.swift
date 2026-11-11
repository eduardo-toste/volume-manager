import Testing

@testable import VolumeCore

/// QA M5.3: the user's print (notice shown after the permission was given, nothing playing)
/// and fail-open edges of the new permission flow.
@MainActor
@Suite("QA M5.3: permission notice edges", .timeLimit(.minutes(1)))
struct QAM53StoreTests {
  private let marked: [String: Any] = ["audioPermissionConfirmed": true]

  /// Mark stored, fresh launch (status undecided), nothing playing, popover opened many times:
  /// never the notice, idle untouched apps are not listed (M5.3 list correction), no system
  /// prompt (no user-action check).
  @Test func markedAndIdleNeverShowsTheNoticeAcrossManyOpenings() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.start([
      h.process("Spotify", pid: 1, playing: false), h.process("Safari", pid: 2, playing: false),
    ])
    for _ in 0..<10 {
      h.store.popoverOpened()
      await h.settle()
      #expect(!h.store.showsPermissionNotice)
      #expect(h.store.rows.isEmpty)
    }
    #expect(!h.access.userActions.contains(true), "opening never asks the system")
    #expect(h.controller.neverTapped)
  }

  /// "Permitir…" clicked with something playing, granted; then everything stops and the
  /// popover is opened repeatedly: still no notice, mark stored.
  @Test func allowGrantedThenIdleNeverShowsTheNotice() async {
    let h = MixerHarness(permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    h.access.answer = .granted
    _ = await h.store.requestAccess()
    #expect(h.settings.audioPermissionConfirmed)
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false)]))
    for _ in 0..<5 {
      h.store.popoverOpened()
      await h.settle()
      #expect(!h.store.showsPermissionNotice)
    }
  }

  /// Marked and the permission found denied by the silence guard, then the app that plays a
  /// call stops and starts several times: the original sound is never held back by the store
  /// (no desired entry survives a denial) and the notice never shows.
  @Test func ambiguousDenialNeverLeavesDesiredTapsWhileDenied() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    h.access.answer = .denied
    await h.store.checkSilentTap()
    for round in 0..<8 {
      h.store.handle(.processes([h.process("Zoom", pid: 1, playing: round % 2 == 1)]))
      await h.settle()
      if h.permission.status == .denied {
        #expect(h.controller.reconcileCalls.last?.isEmpty == true, "round \(round)")
      }
      #expect(!h.store.showsPermissionNotice)
    }
    #expect(h.settings.audioPermissionConfirmed)
  }

  /// A corrupted preference (wrong type for the mark) behaves as "never confirmed": the
  /// notice shows until "Permitir…", and nothing crashes.
  @Test func corruptedMarkIsTreatedAsNotConfirmed() {
    let h = MixerHarness(
      preferences: ["audioPermissionConfirmed": "yes"], permission: .notDetermined)
    h.start([h.process("Zoom", pid: 1, playing: false)])
    #expect(!h.settings.audioPermissionConfirmed)
    #expect(h.store.showsPermissionNotice)
  }

  /// Panic button keeps the mark (it is not a permission decision) and never shows the notice.
  /// The list keeps the playing app; the idle untouched one is not listed (M5.3 correction).
  @Test func restoreKeepsTheMarkAndTheList() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true), h.process("Safari", pid: 2, playing: false)])
    await h.settle()
    h.store.restoreOriginalAudio()
    await h.settle()
    #expect(h.settings.audioPermissionConfirmed)
    #expect(!h.store.showsPermissionNotice)
    #expect(h.store.rows.map(\.app.name) == ["Zoom"])
    #expect(h.controller.reconcileCalls.last?.isEmpty ?? true)
  }
}

/// QA M5.3 final round: the list rules (playing or in a call, 3 s grace) and the live list.
@MainActor
@Suite("QA M5.3: live list", .timeLimit(.minutes(1)))
struct QAM53LiveListTests {
  private let marked: [String: Any] = ["audioPermissionConfirmed": true]

  private func refreshes(_ h: MixerHarness) -> Int {
    h.system.calls.filter { $0 == .refresh }.count
  }

  /// A call listed without ever getting a tap; ending it removes the row 3 s later.
  @Test func callStaysListedWithoutATapAndLeavesThreeSecondsAfterItEnds() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: false, inCall: true)])
    await h.settle()
    #expect(h.store.rows.map(\.app.name) == ["Zoom"])
    #expect(h.controller.neverTapped, "being in a call never creates a tap")
    h.store.handle(.processes([h.process("Zoom", pid: 1, playing: false, inCall: false)]))
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.clock.advance(by: MixerStore.listGracePeriod - .milliseconds(1))
    await Task.yield()
    #expect(h.store.rows.count == 1, "still within the 3 s")
    h.clock.advance(by: .milliseconds(1))
    #expect(await eventually { h.store.rows.isEmpty })
    #expect(h.controller.neverTapped)
  }

  /// An idle app that never played is not listed at all.
  @Test func idleAppIsNotListed() {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Spotify", pid: 1, playing: false)])
    #expect(h.store.rows.isEmpty)
  }

  /// The 1 s re-reading runs only while the popover is open.
  @Test func rereadingRunsOnlyWhileThePopoverIsOpen() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true)])
    await h.settle()
    let idle = refreshes(h)
    h.clock.advance(by: .seconds(30))
    await h.settle()
    #expect(refreshes(h) == idle, "closed: no polling")
    h.store.popoverOpened()
    await h.settle()
    #expect(refreshes(h) == idle + 1, "opening re-reads at once")
    for _ in 0..<5 {
      #expect(await eventually { h.clock.sleeperCount >= 1 })
      h.clock.advance(by: MixerStore.openRefreshInterval)
      await h.settle()
    }
    #expect(refreshes(h) >= idle + 5)
    h.store.popoverClosed()
    await h.settle()
    let closed = refreshes(h)
    h.clock.advance(by: .seconds(30))
    await h.settle()
    #expect(refreshes(h) == closed, "closing stops the timer")
    h.store.popoverOpened()
    h.store.popoverOpened()
    h.store.popoverClosed()
    await h.settle()
    let again = refreshes(h)
    h.clock.advance(by: .seconds(10))
    await h.settle()
    #expect(refreshes(h) == again, "opening twice leaves no timer behind")
  }
}
