import Foundation
import Testing

@testable import VolumeCore

@MainActor
@Suite("SettingsModel")
struct SettingsModelTests {
  let clock = FakeClock()

  private func model(_ store: InMemoryPreferencesStore) -> SettingsModel {
    SettingsModel(store: store, clock: clock)
  }

  @Test func defaultsMatchTheSpec() {
    let settings = model(InMemoryPreferencesStore())
    #expect(settings.launchAtLogin)
    #expect(settings.menuBarIconStyle == .speaker)
    #expect(settings.rememberVolumes)
    #expect(!settings.showInactiveApps)
    #expect(settings.volumeStep == .five)
    #expect(!settings.onboardingCompleted)
    #expect(settings.rememberedApps.isEmpty)
  }

  @Test func savesOnlyAfterTheDebounceDelay() async {
    let store = InMemoryPreferencesStore()
    let settings = model(store)
    settings.rememberVolumes = false
    await Task.yield()
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .milliseconds(499))
    await Task.yield()
    #expect(store.writeCount == 0)
    clock.advance(by: .milliseconds(1))
    #expect(await eventually { store.writeCount > 0 })
    #expect(store.values["rememberVolumes"] as? Bool == false)
  }

  @Test func burstOfChangesCausesOneSave() async {
    let store = InMemoryPreferencesStore()
    let settings = model(store)
    for step in [VolumeStep.one, .ten, .one, .five, .ten] {
      settings.volumeStep = step
      await Task.yield()
    }
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .milliseconds(500))
    #expect(await eventually { store.writeCount > 0 })
    let writes = store.writeCount
    clock.advance(by: .seconds(10))
    await Task.yield()
    #expect(store.writeCount == writes)
    #expect(store.values["volumeStepPercent"] as? Int == 10)
  }

  @Test func newChangeRestartsTheDelay() async {
    let store = InMemoryPreferencesStore()
    let settings = model(store)
    settings.showInactiveApps = true
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .milliseconds(400))
    settings.rememberVolumes = false
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .milliseconds(400))
    await Task.yield()
    #expect(store.writeCount == 0)
    clock.advance(by: .milliseconds(100))
    #expect(await eventually { store.writeCount > 0 })
  }

  @Test func settingTheSameValueDoesNotSave() async {
    let store = InMemoryPreferencesStore()
    let settings = model(store)
    settings.rememberVolumes = true
    settings.menuBarIconStyle = .speaker
    await Task.yield()
    #expect(clock.sleeperCount == 0)
    settings.flush()
    #expect(store.writeCount > 0)
  }

  @Test func flushWritesImmediatelyAndCancelsTheTimer() async {
    let store = InMemoryPreferencesStore()
    let settings = model(store)
    settings.menuBarIconStyle = .controls
    #expect(await eventually { clock.sleeperCount == 1 })
    settings.flush()
    #expect(store.values["menuBarIconStyle"] as? String == "controls")
    #expect(await eventually { clock.sleeperCount == 0 })
  }

  @Test func theMenuBarIconIsAlwaysVisibleSoNoSuchPreferenceIsStored() {
    let store = InMemoryPreferencesStore(["showInMenuBar": false])
    let settings = model(store)
    settings.flush()
    #expect(store.values["showInMenuBar"] as? Bool == false)  // left untouched, never read
    let fresh = InMemoryPreferencesStore()
    model(fresh).flush()
    #expect(fresh.values["showInMenuBar"] == nil)
  }

  @Test func valuesRoundTripThroughTheStore() {
    let store = InMemoryPreferencesStore()
    let first = model(store)
    first.launchAtLogin = false
    first.menuBarIconStyle = .controls
    first.rememberVolumes = false
    first.showInactiveApps = true
    first.volumeStep = .ten
    first.onboardingCompleted = true
    first.remember(
      AppAudioState(volume: 0.3, muted: true, preferredOutputUID: "uid-1"), for: "com.a.A")
    first.flush()
    let second = model(store)
    #expect(!second.launchAtLogin)
    #expect(second.menuBarIconStyle == .controls)
    #expect(!second.rememberVolumes)
    #expect(second.showInactiveApps)
    #expect(second.volumeStep == .ten)
    #expect(second.onboardingCompleted)
    #expect(
      second.remembered(for: "com.a.A")
        == RememberedApp(volume: 0.3, muted: true, outputUID: "uid-1"))
  }

  @Test func rememberAndForget() {
    let settings = model(InMemoryPreferencesStore())
    settings.remember(AppAudioState(volume: 0.5), for: "com.a.A")
    settings.remember(AppAudioState(volume: 0.7), for: "com.b.B")
    #expect(settings.rememberedApps.count == 2)
    settings.forget("com.a.A")
    #expect(settings.remembered(for: "com.a.A") == nil)
    settings.forget("com.unknown.X")
    settings.forgetAll()
    #expect(settings.rememberedApps.isEmpty)
    settings.forgetAll()
  }

  @Test func rememberRejectsInvalidBundleIDs() {
    let settings = model(InMemoryPreferencesStore())
    settings.remember(AppAudioState(volume: 0.5), for: "bad id\u{202E}")
    settings.remember(AppAudioState(volume: 0.5), for: "")
    #expect(settings.rememberedApps.isEmpty)
  }

  @Test func rememberingTheSameRecordDoesNotNotify() {
    let settings = model(InMemoryPreferencesStore())
    var notifications = 0
    settings.onChange { notifications += 1 }
    settings.remember(AppAudioState(volume: 0.5), for: "com.a.A")
    settings.remember(AppAudioState(volume: 0.5), for: "com.a.A")
    #expect(notifications == 1)
  }

  @Test func observersAreNotifiedOfChanges() {
    let settings = model(InMemoryPreferencesStore())
    var notifications = 0
    settings.onChange { notifications += 1 }
    settings.showInactiveApps = true
    settings.showInactiveApps = true
    #expect(notifications == 1)
  }

  @Test func rememberedAppsAreCapped() {
    let settings = model(InMemoryPreferencesStore())
    for index in 0..<(PreferenceValidation.maxRememberedApps + 50) {
      settings.remember(AppAudioState(volume: 0.5), for: "com.app.n\(index)")
    }
    #expect(settings.rememberedApps.count == PreferenceValidation.maxRememberedApps)
    settings.remember(AppAudioState(volume: 0.2), for: "com.app.n0")
    #expect(settings.remembered(for: "com.app.n0")?.volume == 0.2)
  }

  // MARK: Hostile stored values

  @Test func wrongTypesBecomeDefaults() {
    let store = InMemoryPreferencesStore([
      "launchAtLogin": "yes", "rememberVolumes": [1],
      "showInactiveApps": 5.5, "onboardingCompleted": "true",
      "menuBarIconStyle": 42, "volumeStepPercent": "ten", "rememberedApps": "nope",
    ])
    let settings = model(store)
    #expect(settings.launchAtLogin)
    #expect(settings.rememberVolumes)
    #expect(!settings.showInactiveApps)
    #expect(!settings.onboardingCompleted)
    #expect(settings.menuBarIconStyle == .speaker)
    #expect(settings.volumeStep == .five)
    #expect(settings.rememberedApps.isEmpty)
  }

  @Test func unknownEnumValuesBecomeDefaults() {
    let store = InMemoryPreferencesStore([
      "menuBarIconStyle": "rainbow", "volumeStepPercent": 7,
    ])
    let settings = model(store)
    #expect(settings.menuBarIconStyle == .speaker)
    #expect(settings.volumeStep == .five)
    let fractional = model(InMemoryPreferencesStore(["volumeStepPercent": 5.5]))
    #expect(fractional.volumeStep == .five)
    let flag = model(InMemoryPreferencesStore(["volumeStepPercent": true]))
    #expect(flag.volumeStep == .five)
    let huge = model(InMemoryPreferencesStore(["volumeStepPercent": 1e300]))
    #expect(huge.volumeStep == .five)
  }

  @Test func hostileRememberedRecordsFallBackToSafeValues() {
    let huge = String(repeating: "u", count: 100_000)
    let store = InMemoryPreferencesStore([
      "rememberedApps": [
        "com.nan.App": ["volume": Double.nan, "muted": false],
        "com.big.App": ["volume": 7.0, "muted": "yes", "outputUID": 5],
        "com.neg.App": ["volume": -0.1],
        "com.inf.App": ["volume": Double.infinity, "outputUID": huge],
        "com.ctl.App": ["volume": 0.4, "muted": true, "outputUID": "uid\u{202E}x"],
        "com.ok.App": ["volume": 0.4, "muted": true, "outputUID": "good-uid"],
        "com.str.App": ["volume": "0.5"],
        "com.bool.App": ["volume": true],
        "com.notdict.App": "string",
        "bad id": ["volume": 0.1],
        "": ["volume": 0.1],
      ] as [String: Any]
    ])
    let settings = model(store)
    let safe = RememberedApp(volume: 1, muted: false, outputUID: nil)
    #expect(settings.remembered(for: "com.nan.App") == safe)
    #expect(settings.remembered(for: "com.big.App") == safe)
    #expect(settings.remembered(for: "com.neg.App") == safe)
    #expect(settings.remembered(for: "com.inf.App") == safe)
    #expect(settings.remembered(for: "com.str.App") == safe)
    #expect(settings.remembered(for: "com.bool.App") == safe)
    #expect(
      settings.remembered(for: "com.ctl.App")
        == RememberedApp(volume: 0.4, muted: true, outputUID: nil))
    #expect(
      settings.remembered(for: "com.ok.App")
        == RememberedApp(volume: 0.4, muted: true, outputUID: "good-uid"))
    #expect(settings.remembered(for: "com.notdict.App") == nil)
    #expect(settings.rememberedApps.count == 8)
  }

  @Test func tooManyStoredRecordsAreCapped() {
    var many: [String: Any] = [:]
    for index in 0..<(PreferenceValidation.maxRememberedApps + 200) {
      many["com.app.n\(index)"] = ["volume": 0.5]
    }
    let settings = model(InMemoryPreferencesStore(["rememberedApps": many]))
    #expect(settings.rememberedApps.count == PreferenceValidation.maxRememberedApps)
  }

  @Test func loadingNeverWritesOrSchedules() {
    let store = InMemoryPreferencesStore(["launchAtLogin": false])
    _ = model(store)
    #expect(store.writeCount == 0)
    #expect(clock.sleeperCount == 0)
  }

  @Test func menuBarSymbolFollowsTheVolume() {
    let style = MenuBarIconStyle.speaker
    #expect(style.symbolName(volume: 0.5, muted: true) == "speaker.slash.fill")
    #expect(style.symbolName(volume: 0, muted: false) == "speaker.slash.fill")
    #expect(style.symbolName(volume: 0.33, muted: false) == "speaker.wave.1.fill")
    #expect(style.symbolName(volume: 0.5, muted: false) == "speaker.wave.2.fill")
    #expect(style.symbolName(volume: 0.67, muted: false) == "speaker.wave.3.fill")
    #expect(style.symbolName(volume: .nan, muted: false) == "speaker.wave.3.fill")
    #expect(MenuBarIconStyle.controls.symbolName(volume: 0, muted: true) == "slider.horizontal.3")
  }

  @Test func volumeStepFractions() {
    #expect(VolumeStep.one.fraction == 0.01)
    #expect(VolumeStep.five.fraction == 0.05)
    #expect(VolumeStep.ten.fraction == 0.1)
    #expect(VolumeStep.allCases.count == 3)
  }
}
