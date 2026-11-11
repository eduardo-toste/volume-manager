import Testing

@testable import VolumeCore

/// QA M5.3: the user's print (notice shown after the permission was given, nothing playing)
/// and fail-open edges of the new permission flow.
@MainActor
@Suite("QA M5.3: permission notice edges", .timeLimit(.minutes(1)))
struct QAM53StoreTests {
  private let marked: [String: Any] = ["audioPermissionConfirmed": true]

  /// Mark stored, fresh launch (status undecided), nothing playing, popover opened many times:
  /// never the notice, the idle apps are listed, no system prompt (no user-action check).
  @Test func markedAndIdleNeverShowsTheNoticeAcrossManyOpenings() async {
    let h = MixerHarness(preferences: marked, permission: .notDetermined)
    h.start([
      h.process("Spotify", pid: 1, playing: false), h.process("Safari", pid: 2, playing: false),
    ])
    for _ in 0..<10 {
      h.store.popoverOpened()
      await h.settle()
      #expect(!h.store.showsPermissionNotice)
      #expect(h.store.rows.count == 2)
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
  @Test func restoreKeepsTheMarkAndTheList() async {
    let h = MixerHarness(preferences: marked, permission: .granted)
    h.start([h.process("Zoom", pid: 1, playing: true), h.process("Safari", pid: 2, playing: false)])
    await h.settle()
    h.store.restoreOriginalAudio()
    await h.settle()
    #expect(h.settings.audioPermissionConfirmed)
    #expect(!h.store.showsPermissionNotice)
    #expect(h.store.rows.count == 2)
    #expect(h.controller.reconcileCalls.last?.isEmpty ?? true)
  }
}
