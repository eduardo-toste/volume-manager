import Testing

@testable import VolumeCore

/// M7.6 (SPEC 13.2, 3.2, 3.4, 4.6): the permission mark is tied to the build. A mark from
/// another build behaves as "never confirmed" and must never leave an app silent.
@MainActor
@Suite("M7.6: permission mark tied to the build", .timeLimit(.minutes(1)))
struct QAM76Tests {
  private let oldBuild: [String: Any] = [
    "audioPermissionConfirmed": true, "audioPermissionBuild": "0",
    "rememberedApps": ["com.spotify.client": ["volume": 0.4, "muted": false]],
  ]

  /// An update: the mark is dropped, the notice shows, nothing is tapped or checked by itself
  /// (so the system prompt cannot appear unasked) and the app keeps its original sound.
  @Test func updatedBuildShowsNoticeAndNeverTapsOrChecks() async {
    let h = MixerHarness(preferences: oldBuild, permission: .notDetermined)
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    #expect(!h.settings.audioPermissionConfirmed)
    #expect(h.store.showsPermissionNotice)
    #expect(h.access.requests == 0)
    #expect(h.controller.neverTapped)
    #expect(h.store.rows.count == 1, "the list still shows the app")
  }

  /// "Permitir…" afterwards grants, applies the remembered volume and stores the new build.
  @Test func allowingAfterAnUpdateRestoresControlAndStoresTheBuild() async {
    let h = MixerHarness(preferences: oldBuild, permission: .notDetermined)
    h.access.answer = .granted
    h.start([h.process("Spotify", pid: 1, playing: true)])
    await h.settle()
    h.store.allowAccess()
    await h.settle()
    #expect(h.settings.audioPermissionConfirmed)
    #expect(!h.store.showsPermissionNotice)
    #expect(h.controller.reconcileCalls.last?.map(\.app.id) == ["com.spotify.client"])
    h.settings.flush()
    #expect(h.preferences.object(forKey: "audioPermissionBuild") as? String == "1")
  }

  /// The drop is not written at launch; a flush later writes it (no half state: either both
  /// keys describe the old mark, or the mark is off and the build key is gone).
  @Test func droppedMarkIsWrittenConsistentlyOnFlush() {
    let h = MixerHarness(preferences: oldBuild, permission: .notDetermined)
    #expect(h.preferences.object(forKey: "audioPermissionConfirmed") as? Bool == true)
    h.settings.flush()
    #expect(h.preferences.object(forKey: "audioPermissionConfirmed") as? Bool == false)
    #expect(h.preferences.object(forKey: "audioPermissionBuild") == nil)
  }

  /// Hostile build values never keep the mark.
  @Test func hostileStoredBuildValuesDropTheMark() {
    let hostile: [Any] = [
      "", [String](), ["1"], ["a": 1], 1, 1.0, true,
      String(repeating: "1", count: 100_000), "1\u{0}", "١",
    ]
    for value in hostile {
      var prefs = oldBuild
      prefs["audioPermissionBuild"] = value
      let h = MixerHarness(preferences: prefs, permission: .notDetermined)
      #expect(!h.settings.audioPermissionConfirmed, "\(value)")
    }
  }
}
