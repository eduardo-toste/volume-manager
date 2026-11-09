import Foundation
import Synchronization
import Testing

@testable import VolumeCore

// Independent QA tests for M1 (VolumeCore). Tests that expose bugs are marked "QA-BUG" and are
// expected to FAIL until the Dev fixes the code.

private func scalar(_ value: UInt32) -> String {
  guard let unicode = Unicode.Scalar(value) else { return "" }
  return String(Character(unicode))
}

// MARK: - TextSanitizer (SPEC 12.9.4)

@Suite("QA M1: TextSanitizer")
struct QATextSanitizerTests {
  @Test func everyC0C1ScalarIsRemovedOrBecomesSpace() {
    for value in UInt32(0)...0x9F {
      let cleaned = TextSanitizer.clean("a" + scalar(value) + "b")
      let hasControl = cleaned.unicodeScalars.contains {
        $0.properties.generalCategory == .control
      }
      #expect(!hasControl, "control U+\(String(value, radix: 16)) survived")
    }
  }

  @Test func bidiAndZeroWidthAreRemoved() {
    let hostile: [UInt32] =
      [0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060]
      + [0x2066, 0x2067, 0x2068, 0x2069, 0x061C, 0xFEFF]
    for value in hostile {
      #expect(
        TextSanitizer.clean("a" + scalar(value) + "b") == "ab", "U+\(String(value, radix: 16))")
    }
  }

  @Test func combinationsAreCleanedTogether() {
    let text = "\u{202E}\u{200B}Sp\u{0007}ot\u{200F}ify\u{2066}\n\t \u{FEFF}"
    #expect(TextSanitizer.clean(text) == "Spotify")
  }

  /// QA-BUG: other invisible format characters (tags, invisible operators, deprecated format
  /// controls, soft hyphen, interlinear annotation) pass through and can hide or smuggle text.
  @Test(
    arguments: [
      0x00AD, 0x2061, 0x2062, 0x2063, 0x2064, 0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
      0xFFF9, 0xFFFA, 0xFFFB, 0xE0001, 0xE0020, 0xE0041, 0xE007F, 0x180E,
    ] as [UInt32])
  func otherInvisibleFormatCharactersAreRemoved(value: UInt32) {
    #expect(
      TextSanitizer.clean("a" + scalar(value) + "b") == "ab",
      "U+\(String(value, radix: 16)) survived")
  }

  @Test func asciiSmugglingWithTagCharactersLeavesNothingInvisible() {
    let hidden =
      "Spotify"
      + String(
        String.UnicodeScalarView(
          "ignore".unicodeScalars.map {
            Unicode.Scalar($0.value + 0xE0000) ?? $0
          }))
    #expect(TextSanitizer.clean(hidden) == "Spotify")
  }

  @Test func legitimateUnicodeIsPreserved() {
    for text in ["Música", "日本語アプリ", "Ünïcödé", "Приложение", "تطبيق", "🎵 Spotify", "🇧🇷"] {
      #expect(TextSanitizer.clean(text) == text)
    }
    #expect(TextSanitizer.clean("e\u{0301}") == "e\u{0301}")
    #expect(TextSanitizer.clean("❤️") == "❤️")
  }

  /// QA-BUG (Low): the zero-width joiner/non-joiner are legitimate in emoji sequences and in
  /// Persian/Indic text; stripping them breaks the characters.
  @Test func zeroWidthJoinerEmojiSequencesSurvive() {
    let family = "👨\u{200D}👩\u{200D}👧"
    #expect(TextSanitizer.clean(family) == family)
  }

  @Test func tenMegabyteInputIsBoundedAndFast() {
    let huge = String(repeating: "a\u{200B}b ", count: 2_500_000)
    #expect(huge.utf8.count > 10_000_000)
    let start = ContinuousClock.now
    let cleaned = TextSanitizer.clean(huge)
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .seconds(1), "took \(elapsed)")
    #expect(cleaned.count <= TextSanitizer.maxLength)
    #expect(cleaned.utf8.count <= TextSanitizer.maxLength * 4)
  }

  @Test func tenMegabytesOfCombiningMarksAreBounded() {
    let huge = "e" + String(repeating: "\u{0301}", count: 5_000_000)
    let start = ContinuousClock.now
    let cleaned = TextSanitizer.clean(huge)
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(cleaned.utf8.count <= TextSanitizer.maxLength * 4)
  }

  @Test func tenMegabytesOfWhitespaceBecomeEmpty() {
    #expect(TextSanitizer.clean(String(repeating: " ", count: 10_000_000)) == "")
  }

  @Test func limitsAreHonored() {
    #expect(TextSanitizer.clean("abcdef", limit: 3) == "abc")
    #expect(TextSanitizer.clean("abc", limit: 0) == "")
    #expect(TextSanitizer.clean("abc", limit: -5) == "")
    #expect(TextSanitizer.clean(String(repeating: "x", count: 1000)).count == 200)
  }

  /// A 10 MB value in storage must not stall the validation of a remembered record.
  @Test @MainActor func tenMegabyteStoredUIDIsRejectedQuickly() {
    let huge = String(repeating: "u", count: 10_000_000)
    let store = InMemoryPreferencesStore([
      "rememberedApps": ["com.spotify.client": ["volume": 0.5, "outputUID": huge]]
    ])
    let start = ContinuousClock.now
    let settings = SettingsModel(store: store, clock: FakeClock())
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(settings.remembered(for: "com.spotify.client")?.outputUID == nil)
    #expect(settings.remembered(for: "com.spotify.client")?.volume == 0.5)
  }
}

// MARK: - ProcessGrouping with hostile input

@Suite("QA M1: ProcessGrouping")
struct QAProcessGroupingTests {
  private func info() -> FakeAppInfoProvider {
    let info = FakeAppInfoProvider()
    info.setApp("/Applications/Spotify.app", name: "Spotify", bundleID: "com.spotify.client")
    info.setApp(
      "/Applications/Google Chrome.app", name: "Google Chrome", bundleID: "com.google.Chrome")
    info.setApp(
      "/Applications/Volume Manager.app", name: "Volume Manager", bundleID: "com.volumemanager.app")
    return info
  }

  @Test func dotDotCannotImpersonateAnotherApp() {
    let processes = [
      AudioProcessInfo(
        pid: 10,
        executablePath: "/tmp/Evil.app/Contents/../../x/Spotify.app/../../bin/tool",
        isRunningOutput: true)
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func dotDotResolvesToTheRealOwner() {
    let processes = [
      AudioProcessInfo(
        pid: 10,
        executablePath: "/Applications/Evil.app/Contents/../../Spotify.app/Contents/MacOS/Spotify")
    ]
    let apps = ProcessGrouping.group(processes, info: info())
    #expect(apps.map(\.id) == ["com.spotify.client"])
  }

  @Test func leavingTheAppBundleWithDotDotLosesTheOwnership() {
    let processes = [
      AudioProcessInfo(
        pid: 10, bundleID: "com.evil.thing",
        executablePath: "/Applications/Spotify.app/Contents/MacOS/../../../../usr/bin/afplay")
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func relativeAndControlCharacterPathsAreNotTrusted() {
    let processes = [
      AudioProcessInfo(
        pid: 1, bundleID: "com.spotify.client",
        executablePath: "Spotify.app/Contents/MacOS/Spotify"),
      AudioProcessInfo(
        pid: 2, bundleID: "com.spotify.client",
        executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify\n/x"),
    ]
    let apps = ProcessGrouping.group(processes, info: info())
    #expect(apps.count == 1)
    #expect(apps[0].pids == [1, 2])
    #expect(apps[0].id == "com.spotify.client")
  }

  @Test func nestedHelperAppGroupsUnderTheOutermostApp() {
    let chrome = "/Applications/Google Chrome.app/Contents"
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "\(chrome)/MacOS/Google Chrome"),
      AudioProcessInfo(
        pid: 2,
        executablePath:
          "\(chrome)/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        isRunningOutput: true),
      AudioProcessInfo(
        pid: 3,
        executablePath:
          "\(chrome)/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/h"
      ),
    ]
    let apps = ProcessGrouping.group(processes, info: info())
    #expect(apps.count == 1)
    #expect(apps[0].id == "com.google.Chrome")
    #expect(apps[0].pids == [1, 2, 3])
    #expect(apps[0].isPlaying)
    #expect(apps[0].name == "Google Chrome")
  }

  @Test func appSuffixWithoutContentsIsNotAnApp() {
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Users/x/folder.app/bin/tool"),
      AudioProcessInfo(pid: 2, executablePath: "/Applications/.app/Contents/MacOS/tool"),
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func uppercaseAppExtensionIsRecognized() {
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Applications/Spotify.APP/Contents/MacOS/Spotify")
    ]
    #expect(ProcessGrouping.group(processes, info: info()).count == 1)
  }

  @Test func hostileBundleIDsAreRejected() {
    let hostile = [
      String(repeating: "a.", count: 100_000), "com.evil\u{202E}.app", "com.evil app", "../../x",
      "com/evil/app", "", "...", "\u{0}", "com.évil.app", "com.evil.app\n",
    ]
    for bundleID in hostile {
      let processes = [AudioProcessInfo(pid: 5, bundleID: bundleID, isRunningOutput: true)]
      #expect(
        ProcessGrouping.group(processes, info: info()).isEmpty,
        "accepted \(bundleID.prefix(30).debugDescription)")
    }
  }

  @Test func processWithoutBundleIDAndPathIsExcluded() {
    #expect(ProcessGrouping.group([AudioProcessInfo(pid: 5)], info: info()).isEmpty)
  }

  @Test func nonPositivePIDsAreExcluded() {
    let processes = [
      AudioProcessInfo(pid: 0, bundleID: "com.spotify.client"),
      AudioProcessInfo(pid: -1, bundleID: "com.spotify.client"),
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func systemDaemonsAreExcludedEvenWithAFriendlyBundleID() {
    let processes = [
      AudioProcessInfo(
        pid: 5, bundleID: "com.apple.coreaudiod", executablePath: "/usr/sbin/coreaudiod"),
      AudioProcessInfo(
        pid: 6, bundleID: "com.apple.systemsounds",
        executablePath: "/System/Library/CoreServices/soundd"),
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func volumeItselfAndItsHelpersAreExcluded() {
    let processes = [
      AudioProcessInfo(
        pid: 1, executablePath: "/Applications/Volume Manager.app/Contents/MacOS/VolumeManager"),
      AudioProcessInfo(
        pid: 2, bundleID: "com.volumemanager.app.helper",
        executablePath:
          "/Applications/Volume Manager.app/Contents/XPCServices/H.xpc/Contents/MacOS/H"),
      AudioProcessInfo(pid: 3, bundleID: "com.volumemanager.app.xpc"),
      AudioProcessInfo(pid: 4, bundleID: "com.volumemanager.app"),
    ]
    #expect(ProcessGrouping.group(processes, info: info()).isEmpty)
  }

  @Test func helperWhoseResponsibleProcessIsVolumeIsExcluded() {
    let fake = info()
    fake.setPath("/Applications/Volume Manager.app/Contents/MacOS/VolumeManager", forPID: 1)
    let processes = [AudioProcessInfo(pid: 9, bundleID: "com.apple.WebKit.GPU", responsiblePID: 1)]
    #expect(ProcessGrouping.group(processes, info: fake).isEmpty)
  }

  /// QA-BUG (Low): if the bundle ID of Volume's own .app cannot be read and the process carries
  /// no bundle ID, Volume is not excluded (exclusion depends only on bundle IDs).
  @Test func volumeIsExcludedByPathEvenWhenItsPlistIsUnreadable() {
    let fake = FakeAppInfoProvider()
    let processes = [
      AudioProcessInfo(
        pid: 1, executablePath: "/Applications/Volume Manager.app/Contents/MacOS/VolumeManager",
        isRunningOutput: true)
    ]
    #expect(ProcessGrouping.group(processes, info: fake).isEmpty)
  }

  @Test func hostileNamesAreSanitizedAndTruncated() {
    let fake = FakeAppInfoProvider()
    fake.setApp(
      "/Applications/Spotify.app",
      name: "\u{202E}Spo\u{0007}tify" + String(repeating: "x", count: 100_000),
      bundleID: "com.spotify.client")
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Applications/Spotify.app/Contents/MacOS/S")
    ]
    let name = ProcessGrouping.group(processes, info: fake)[0].name
    #expect(name.hasPrefix("Spotify"))
    #expect(name.count <= TextSanitizer.maxLength)
    #expect(!name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x202E })
  }

  @Test func appWithoutBundleIDGetsAPathKeyAndDuplicatesPidsCollapse() {
    let fake = FakeAppInfoProvider()
    let processes = [
      AudioProcessInfo(pid: 7, executablePath: "/Users/x/Tool.app/Contents/MacOS/Tool"),
      AudioProcessInfo(pid: 7, executablePath: "/Users/x/Tool.app/Contents/MacOS/Tool"),
    ]
    let apps = ProcessGrouping.group(processes, info: fake)
    #expect(apps.count == 1)
    #expect(apps[0].id == "path:/Users/x/Tool.app")
    #expect(apps[0].bundleID == nil)
    #expect(apps[0].pids == [7])
    #expect(apps[0].name == "Tool")
  }

  @Test func twoAppsWithTheSameNameStaySeparate() {
    let fake = FakeAppInfoProvider()
    fake.setApp("/Applications/A/Player.app", name: "Player", bundleID: "com.a.player")
    fake.setApp("/Applications/B/Player.app", name: "Player", bundleID: "com.b.player")
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Applications/A/Player.app/Contents/MacOS/p"),
      AudioProcessInfo(pid: 2, executablePath: "/Applications/B/Player.app/Contents/MacOS/p"),
    ]
    let apps = ProcessGrouping.group(processes, info: fake)
    #expect(apps.map(\.id) == ["com.a.player", "com.b.player"])
    #expect(apps.map(\.pids) == [[1], [2]])
  }

  @Test func groupingIsIndependentOfInputOrder() {
    let fake = info()
    let list = [
      AudioProcessInfo(pid: 1, executablePath: "/Applications/Spotify.app/Contents/MacOS/S"),
      AudioProcessInfo(pid: 2, executablePath: "/Applications/Google Chrome.app/Contents/MacOS/C"),
      AudioProcessInfo(pid: 3, executablePath: "/Applications/Spotify.app/Contents/Helper"),
    ]
    #expect(
      ProcessGrouping.group(list, info: fake) == ProcessGrouping.group(list.reversed(), info: fake))
  }
}

// MARK: - SettingsModel and corrupted preferences

@MainActor
@Suite("QA M1: SettingsModel")
struct QASettingsModelTests {
  let clock = FakeClock()

  @Test func defaultsMatchSpec33() {
    let settings = SettingsModel(store: InMemoryPreferencesStore(), clock: clock)
    #expect(settings.launchAtLogin == true)
    #expect(settings.menuBarIconStyle == .speaker)
    #expect(settings.rememberVolumes == true)
    #expect(settings.showInactiveApps == false)
    #expect(settings.volumeStep == .five)
    #expect(VolumeStep.allCases.map(\.rawValue) == [1, 5, 10])
  }

  @Test func wrongTypesFallBackToDefaults() {
    let wrong: [String: Any] = [
      "launchAtLogin": "false", "menuBarIconStyle": 5,
      "rememberVolumes": [true], "showInactiveApps": "yes", "volumeStepPercent": "10",
      "onboardingCompleted": 1, "rememberedApps": ["not", "a", "dict"],
    ]
    let settings = SettingsModel(store: InMemoryPreferencesStore(wrong), clock: clock)
    #expect(settings.launchAtLogin)
    #expect(settings.menuBarIconStyle == .speaker)
    #expect(settings.rememberVolumes)
    #expect(!settings.showInactiveApps)
    #expect(settings.volumeStep == .five)
    #expect(!settings.onboardingCompleted)
    #expect(settings.rememberedApps.isEmpty)
  }

  @Test func invalidVolumeStepFallsBack() {
    let values: [Any] = [7, 0, -1, 100, 5.5, Double.nan, Double.infinity, true, "5"]
    for value in values {
      let settings = SettingsModel(
        store: InMemoryPreferencesStore(["volumeStepPercent": value]), clock: clock)
      #expect(settings.volumeStep == .five, "\(value)")
    }
  }

  @Test func corruptedRememberedRecordsNeverMuteOrBreak() {
    let records: [String: Any] = [
      "com.a.neg": ["volume": -5.0],
      "com.a.big": ["volume": 999],
      "com.a.nan": ["volume": Double.nan],
      "com.a.inf": ["volume": Double.infinity],
      "com.a.str": ["volume": "0.5", "muted": "yes", "outputUID": 42],
      "com.a.bool": ["volume": true],
      "com.a.empty": [String: Any](),
      "com.a.huge": ["volume": 0.4, "outputUID": String(repeating: "u", count: 5000)],
      "com.a.ctrl": ["volume": 0.4, "outputUID": "dev\u{202E}ice"],
      "not a bundle id": ["volume": 0.2],
      "com.a.notdict": 12,
    ]
    let settings = SettingsModel(
      store: InMemoryPreferencesStore(["rememberedApps": records]), clock: clock)
    for key in [
      "com.a.neg", "com.a.big", "com.a.nan", "com.a.inf", "com.a.str", "com.a.bool", "com.a.empty",
    ] {
      let record = settings.remembered(for: key)
      #expect(record?.volume == 1, "\(key)")
      #expect(record?.muted == false, "\(key)")
      #expect(record?.outputUID == nil, "\(key)")
    }
    #expect(settings.remembered(for: "com.a.huge")?.outputUID == nil)
    #expect(settings.remembered(for: "com.a.ctrl")?.outputUID == nil)
    #expect(settings.remembered(for: "com.a.huge")?.volume == 0.4)
    #expect(settings.remembered(for: "not a bundle id") == nil)
    #expect(settings.remembered(for: "com.a.notdict") == nil)
  }

  @Test func loadingMoreThanTheLimitKeepsExactlyTheLimit() {
    var records: [String: Any] = [:]
    for index in 0..<5000 { records["com.test.app\(index)"] = ["volume": 0.5] }
    let settings = SettingsModel(
      store: InMemoryPreferencesStore(["rememberedApps": records]), clock: clock)
    #expect(settings.rememberedApps.count == 1000)
  }

  @Test func rememberingStopsAtTheLimitButExistingAppsStillUpdate() {
    let settings = SettingsModel(store: InMemoryPreferencesStore(), clock: clock)
    for index in 0..<1000 {
      settings.remember(AppAudioState(volume: 0.5), for: "com.test.app\(index)")
    }
    #expect(settings.rememberedApps.count == 1000)
    settings.remember(AppAudioState(volume: 0.5), for: "com.test.extra")
    #expect(settings.rememberedApps.count == 1000)
    #expect(settings.remembered(for: "com.test.extra") == nil)
    settings.remember(AppAudioState(volume: 0.1), for: "com.test.app7")
    #expect(settings.remembered(for: "com.test.app7")?.volume == 0.1)
    settings.forget("com.test.app0")
    settings.remember(AppAudioState(volume: 0.5), for: "com.test.extra")
    #expect(settings.remembered(for: "com.test.extra") != nil)
  }

  @Test func rememberRejectsInvalidBundleIDs() {
    let settings = SettingsModel(store: InMemoryPreferencesStore(), clock: clock)
    settings.remember(AppAudioState(volume: 0.5), for: "bad id\n")
    settings.remember(AppAudioState(volume: 0.5), for: String(repeating: "a", count: 5000))
    #expect(settings.rememberedApps.isEmpty)
  }

  @Test func manyQuickChangesProduceASingleWrite() async {
    let store = InMemoryPreferencesStore()
    let settings = SettingsModel(store: store, clock: clock)
    for index in 0..<20 {
      settings.remember(AppAudioState(volume: Double(index) / 25), for: "com.test.app")
      #expect(await eventually { clock.sleeperCount == 1 })
      clock.advance(by: .milliseconds(100))
    }
    #expect(store.writeCount == 0)
    clock.advance(by: .milliseconds(500))
    #expect(await eventually { store.writeCount > 0 })
    let afterFirstSave = store.writeCount
    clock.advance(by: .seconds(30))
    await Task.yield()
    #expect(store.writeCount == afterFirstSave)
    let saved = store.values["rememberedApps"] as? [String: Any]
    #expect((saved?["com.test.app"] as? [String: Any])?["volume"] as? Double == 19.0 / 25)
  }

  @Test func flushWritesAtOnceAndCancelsThePendingSave() async {
    let store = InMemoryPreferencesStore()
    let settings = SettingsModel(store: store, clock: clock)
    settings.showInactiveApps = true
    #expect(await eventually { clock.sleeperCount == 1 })
    settings.flush()
    let written = store.writeCount
    #expect(written > 0)
    #expect(store.values["showInactiveApps"] as? Bool == true)
    clock.advance(by: .seconds(5))
    await Task.yield()
    #expect(store.writeCount == written)
  }

  @Test func settingTheSameValueDoesNotScheduleASave() async {
    let store = InMemoryPreferencesStore()
    let settings = SettingsModel(store: store, clock: clock)
    settings.rememberVolumes = true
    settings.forget("com.unknown.app")
    settings.forgetAll()
    await Task.yield()
    #expect(clock.sleeperCount == 0)
    #expect(store.writeCount == 0)
  }

  @Test func savedPreferencesRoundTripThroughAFreshModel() {
    let store = InMemoryPreferencesStore()
    let first = SettingsModel(store: store, clock: clock)
    first.volumeStep = .ten
    first.menuBarIconStyle = .controls
    first.remember(
      AppAudioState(volume: 0.3, muted: true, preferredOutputUID: "dev1"), for: "com.a.b")
    first.flush()
    let second = SettingsModel(store: store, clock: clock)
    #expect(second.volumeStep == .ten)
    #expect(second.menuBarIconStyle == .controls)
    #expect(
      second.remembered(for: "com.a.b")
        == RememberedApp(volume: 0.3, muted: true, outputUID: "dev1"))
  }
}

// MARK: - SafetyPolicy

@MainActor
@Suite("QA M1: SafetyPolicy")
struct QASafetyPolicyTests {
  let clock = FakeClock()

  @Test func garbageInTheStoreNeverCrashesAndNeverForcesSafeModeByTypeConfusion() {
    let store = InMemoryPreferencesStore([
      "safety.sessionStarted": "yes", "safety.cleanExit": 7, "safety.stable": [1],
      "safety.earlyCrashes": Double.nan,
    ])
    let policy = SafetyPolicy(store: store, clock: clock)
    policy.beginSession()
    #expect(!policy.isSafeMode)
  }

  @Test func absurdCrashCountsAreClamped() {
    let store = InMemoryPreferencesStore([
      "safety.sessionStarted": true, "safety.earlyCrashes": 100_000_000,
    ])
    let policy = SafetyPolicy(store: store, clock: clock)
    policy.beginSession()
    #expect(policy.isSafeMode)
    #expect((store.values["safety.earlyCrashes"] as? Int ?? 0) <= 101)
    let negative = InMemoryPreferencesStore([
      "safety.sessionStarted": true, "safety.earlyCrashes": -50,
    ])
    let other = SafetyPolicy(store: negative, clock: clock)
    other.beginSession()
    #expect(!other.isSafeMode)
  }

  @Test func twoEarlyCrashesInARowTriggerSafeModeButOneDoesNot() {
    let store = InMemoryPreferencesStore()
    let first = SafetyPolicy(store: store, clock: clock)
    first.beginSession()
    #expect(!first.isSafeMode)
    let second = SafetyPolicy(store: store, clock: clock)
    second.beginSession()
    #expect(!second.isSafeMode)
    let third = SafetyPolicy(store: store, clock: clock)
    third.beginSession()
    #expect(third.isSafeMode)
  }

  @Test func aStableSessionBreaksTheStreak() async {
    let store = InMemoryPreferencesStore()
    let first = SafetyPolicy(store: store, clock: clock)
    first.beginSession()
    let second = SafetyPolicy(store: store, clock: clock)
    second.beginSession()
    #expect(await eventually { clock.sleeperCount == 2 })
    clock.advance(by: .seconds(60))
    #expect(await eventually { store.values["safety.stable"] as? Bool == true })
    let third = SafetyPolicy(store: store, clock: clock)
    third.beginSession()
    #expect(!third.isSafeMode)
  }

  @Test func justUnderAMinuteIsNotStable() async {
    let store = InMemoryPreferencesStore()
    let first = SafetyPolicy(store: store, clock: clock)
    first.beginSession()
    #expect(await eventually { clock.sleeperCount == 1 })
    clock.advance(by: .milliseconds(59_999))
    await Task.yield()
    #expect(store.values["safety.stable"] as? Bool == false)
  }

  @Test func aCleanExitResetsEverything() {
    let store = InMemoryPreferencesStore()
    SafetyPolicy(store: store, clock: clock).beginSession()
    SafetyPolicy(store: store, clock: clock).beginSession()
    let third = SafetyPolicy(store: store, clock: clock)
    third.beginSession()
    third.markCleanExit()
    let fourth = SafetyPolicy(store: store, clock: clock)
    fourth.beginSession()
    #expect(!fourth.isSafeMode)
  }
}

// MARK: - MixerStore behavior

@MainActor
@Suite("QA M1: MixerStore")
struct QAMixerStoreTests {
  private func lastDesired(_ h: MixerHarness) async -> [DesiredAppAudio] {
    await h.settle()
    return h.controller.reconcileCalls.last ?? []
  }

  // MARK: Rule "no tap"

  /// SPEC 4.2 "sempre controlar": a playing app keeps one entry through every change; at
  /// 100%, not muted, on the default output it is exactly the original sound (gain 1).
  @Test func playingAppKeepsOneEntryAndIsUnchangedAtFullVolumeOnTheDefaultOutput() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))
    #expect(await lastDesired(h).count == 1)

    h.store.setVolume(0.99, for: "com.spotify.client")
    #expect(await lastDesired(h).first.map { $0.gain < 1 } == true)
    h.store.setVolume(1, for: "com.spotify.client")
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))

    h.store.toggleMute("com.spotify.client")
    #expect(await lastDesired(h).first?.muted == true)
    h.store.toggleMute("com.spotify.client")
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))

    h.store.route("com.spotify.client", to: "airpods")
    #expect(await lastDesired(h).first?.targetDeviceUID == "airpods")
    h.store.route("com.spotify.client", to: nil)
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))
    h.store.route("com.spotify.client", to: "speakers")
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))
    #expect(h.controller.reconcileCalls.allSatisfy { $0.count == 1 }, "never without its tap")
  }

  @Test func tinyVolumeBelowOneStillNeedsATapAndNeverBecomesMute() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.0001, for: "com.spotify.client")
    let desired = await lastDesired(h)
    #expect(desired.count == 1)
    #expect(desired[0].muted == false)
    #expect(desired[0].gain > 0 && desired[0].gain < 1)
  }

  @Test func routeToTheCurrentDefaultThenDefaultMovesKeepsExplicitChoice() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route("com.spotify.client", to: "speakers")
    h.store.handle(.defaultOutput(uid: "airpods"))
    let desired = await lastDesired(h)
    #expect(desired.first?.targetDeviceUID == "speakers")
  }

  // MARK: Idempotence

  @Test func sameStateIsNotResentButRealChangesAre() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: "com.spotify.client")
    await h.settle()
    let baseline = h.controller.reconcileCalls.count

    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    h.store.handle(.devices([MixerHarness.speakers, MixerHarness.airpods]))
    h.store.handle(.defaultOutput(uid: "speakers"))
    h.store.setVolume(0.5, for: "com.spotify.client")
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline)

    h.store.handle(
      .processes([
        h.process("Spotify", pid: 1, playing: true), h.process("Spotify", pid: 2, playing: true),
      ]))
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline + 1)
    #expect(h.controller.reconcileCalls.last?.first?.app.pids == [1, 2])

    h.store.handle(.defaultOutput(uid: "airpods"))
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline + 2)
    #expect(h.controller.reconcileCalls.last?.first?.targetDeviceUID == "airpods")
  }

  /// QA-BUG (Low): `DesiredAppAudio` embeds the whole `AudioApp`, including `isPlaying`, so a
  /// pause/resume of a tapped app (no change to gain, mute, device or PIDs) is re-sent.
  @Test func playPauseOfATappedAppDoesNotResendTheDesiredState() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: "com.spotify.client")
    await h.settle()
    let baseline = h.controller.reconcileCalls.count
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline)
  }

  // MARK: Never silence by accident

  @Test func unknownDefaultOutputLeavesAppsUntouchedInsteadOfGuessing() async {
    let h = MixerHarness()
    h.store.handle(.devices([MixerHarness.speakers]))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    h.store.setVolume(0.3, for: "com.spotify.client")
    h.store.toggleMute("com.spotify.client")
    #expect(await lastDesired(h).isEmpty)
    #expect(h.controller.neverTapped)
    h.store.handle(.defaultOutput(uid: "speakers"))
    let desired = await lastDesired(h)
    #expect(desired.count == 1 && desired[0].muted)
    h.store.handle(.defaultOutput(uid: nil))
    #expect(await lastDesired(h).isEmpty)
  }

  @Test func deviceRemovedDuringRouteFallsBackWithoutMutingThenComesBack() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: "com.spotify.client")
    h.store.route("com.spotify.client", to: "airpods")
    h.store.handle(.devices([MixerHarness.speakers]))
    var desired = await lastDesired(h)
    #expect(desired.first?.targetDeviceUID == "speakers")
    #expect(desired.first?.muted == false)
    #expect(h.store.rows.first?.savedDeviceMissing == true)
    h.store.handle(.devices([MixerHarness.speakers, MixerHarness.airpods]))
    desired = await lastDesired(h)
    #expect(desired.first?.targetDeviceUID == "airpods")
  }

  @Test func deviceRemovedAtFullVolumeFallsBackToTheUnchangedDefault() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.route("com.spotify.client", to: "airpods")
    #expect(await lastDesired(h).first?.targetDeviceUID == "airpods")
    h.store.handle(.devices([MixerHarness.speakers]))
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))
  }

  @Test func corruptedRememberedStateNeverSilencesTheApp() async {
    let h = MixerHarness(preferences: [
      "rememberedApps": [
        "com.spotify.client": ["volume": -5.0, "muted": "true", "outputUID": 12],
        "us.zoom.xos": ["volume": Double.nan],
        "com.apple.Safari": ["volume": 999],
      ]
    ])
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Zoom", pid: 2, playing: true),
      h.process("Safari", pid: 3, playing: true),
    ])
    #expect(await lastDesired(h).count == 3)
    #expect(h.controller.onlyUnchangedAudio)
    for row in h.store.rows { #expect(row.state == .default) }
  }

  @Test func safeModeDoesNotApplyARememberedMuteAndKeepsTheMemory() async {
    let h = MixerHarness(
      preferences: [
        "safety.sessionStarted": true, "safety.cleanExit": false, "safety.stable": false,
        "safety.earlyCrashes": 1,
        "rememberedApps": ["com.spotify.client": ["volume": 0.2, "muted": true]],
      ], beginSafety: true)
    #expect(h.store.isSafeMode)
    h.start([h.process("Spotify", pid: 1, playing: true)])
    #expect(SpyAppAudioController.isUnchanged(await lastDesired(h)))
    #expect(h.controller.onlyUnchangedAudio)
    #expect(h.settings.remembered(for: "com.spotify.client")?.muted == true)
    #expect(h.store.rows.first?.state == .default)
  }

  @Test func restoreDuringDebounceLeavesNothingRememberedOnDisk() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.3, for: "com.spotify.client")
    h.store.toggleMute("com.spotify.client")
    #expect(await eventually { h.clock.sleeperCount >= 1 })
    h.store.restoreOriginalAudio()
    #expect(await eventually { h.clock.sleeperCount == 1 })
    h.clock.advance(by: .milliseconds(500))
    #expect(await eventually { h.preferences.writeCount > 0 })
    let saved = h.preferences.values["rememberedApps"] as? [String: Any]
    #expect(saved?.isEmpty ?? true)
    await h.settle()
    #expect(h.controller.restoreAllCount == 1)
    #expect(h.controller.reconcileCalls.last?.isEmpty ?? true)
    let afterRestart = SettingsModel(store: h.preferences, clock: FakeClock())
    #expect(afterRestart.remembered(for: "com.spotify.client") == nil)
  }

  @Test func appThatReappearsAfterRestoreStartsAtOriginalAudio() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.3, for: "com.spotify.client")
    h.store.restoreOriginalAudio()
    h.store.handle(.processes([]))
    h.store.handle(.processes([h.process("Spotify", pid: 9, playing: true)]))
    #expect(await lastDesired(h).isEmpty)
    #expect(h.store.rows.first?.state == .default)
  }

  /// QA-BUG (Medium): `restoreOriginalAudio` only resets apps present in the process list at
  /// that moment. An app that was muted/lowered, then left the list (for example quit or was
  /// between sessions) keeps its in-memory state and comes back muted after the panic button.
  @Test func panicAlsoResetsAppsThatAreTemporarilyAbsent() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleMute("com.spotify.client")
    h.store.handle(.processes([]))
    h.store.restoreOriginalAudio()
    h.store.handle(.processes([h.process("Spotify", pid: 2, playing: true)]))
    #expect(h.store.rows.first?.state == .default)
    #expect(await lastDesired(h).isEmpty)
  }

  /// The panic button must not wait behind a stuck `reconcile` (SPEC 4.6: "imediatamente").
  @Test func restoreIsNotQueuedBehindAHangingReconcile() async {
    let controller = HangingController()
    let clock = FakeClock()
    let preferences = InMemoryPreferencesStore()
    let settings = SettingsModel(store: preferences, clock: clock)
    let store = MixerStore(
      audioSystem: FakeAudioSystem(), controller: controller, appInfo: FakeAppInfoProvider(),
      settings: settings, safety: SafetyPolicy(store: preferences, clock: clock), clock: clock,
      permission: grantedPermission())
    store.handle(.devices([MixerHarness.speakers]))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(
      .processes([
        AudioProcessInfo(
          pid: 1, bundleID: "com.spotify.client", isRunningOutput: true)
      ]))
    store.setVolume(0.5, for: "com.spotify.client")
    #expect(await eventually { controller.reconcileStarted })
    store.restoreOriginalAudio()
    #expect(await eventually { controller.restoreCalled })
    controller.release()
  }

  // MARK: Out-of-order / fast events

  @Test func processGoneBeforeItEverPlayedLeavesNoRowTimerOrTap() async {
    let h = MixerHarness()
    h.start([])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(h.store.rows.isEmpty)
    h.store.handle(.processes([]))
    await Task.yield()
    #expect(h.store.rows.isEmpty)
    #expect(h.clock.sleeperCount == 0)
    #expect(h.controller.neverTapped)
  }

  @Test func stopAndResumeWithinFiveSecondsNeverBlinksNorLosesTheVolume() async {
    let h = MixerHarness()
    h.settings.rememberVolumes = false
    h.settings.flush()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.4, for: "com.spotify.client")
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })  // list timer + tap linger
    h.clock.advance(by: .seconds(4))
    #expect(h.store.rows.count == 1)
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    h.clock.advance(by: .seconds(30))
    await Task.yield()
    #expect(h.store.rows.count == 1)
    #expect(h.store.rows.first?.state.volume == 0.4)
    await h.settle()
    #expect(h.controller.reconcileCalls.dropFirst().allSatisfy { !$0.isEmpty })
  }

  @Test func secondStopStartsAFreshFiveSecondWindow() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })  // list timer + tap linger
    h.clock.advance(by: .seconds(4))
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(await eventually { h.clock.sleeperCount == 0 })
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: false)]))
    #expect(await eventually { h.clock.sleeperCount == 2 })
    h.clock.advance(by: .seconds(1))
    await Task.yield()
    #expect(h.store.rows.count == 1)
    h.clock.advance(by: .seconds(4))
    #expect(await eventually { h.store.rows.isEmpty })
  }

  @Test func reusedPIDOfAnotherAppDoesNotInheritTheOldState() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 100, playing: true)])
    h.store.setVolume(0.2, for: "com.spotify.client")
    h.store.toggleMute("com.spotify.client")
    h.store.handle(.processes([h.process("Zoom", pid: 100, playing: true)]))
    #expect(h.store.rows.map(\.id) == ["us.zoom.xos"])
    #expect(h.store.rows[0].state == .default)
    let zoom = await lastDesired(h)
    #expect(zoom.map(\.app.id) == ["us.zoom.xos"])
    #expect(SpyAppAudioController.isUnchanged(zoom), "Zoom does not inherit Spotify's state")
  }

  @Test func reusedPIDOfTheSameAppInOneEventKeepsOnlyTheNewGroupPIDs() async {
    let h = MixerHarness()
    h.start([
      h.process("Spotify", pid: 100, playing: true), h.process("Zoom", pid: 200, playing: true),
    ])
    h.store.setVolume(0.5, for: "com.spotify.client")
    h.store.handle(
      .processes([
        h.process("Zoom", pid: 100, playing: true), h.process("Spotify", pid: 300, playing: true),
      ]))
    let desired = await lastDesired(h)
    let spotify = desired.first { $0.app.id == "com.spotify.client" }
    #expect(desired.count == 2)
    #expect(spotify?.app.pids == [300])
    #expect(spotify?.gain ?? 1 < 1)
    #expect(SpyAppAudioController.isUnchanged(desired.filter { $0.app.id == "us.zoom.xos" }))
  }

  @Test func twoAppsWithTheSameDisplayNameAreSeparateRowsWithIndependentState() async {
    let h = MixerHarness()
    h.info.setApp("/Applications/A/Zoom.app", name: "Zoom", bundleID: "com.other.zoom")
    h.start([
      h.process("Zoom", pid: 1, playing: true),
      AudioProcessInfo(
        pid: 2, executablePath: "/Applications/A/Zoom.app/Contents/MacOS/Zoom",
        isRunningOutput: true),
    ])
    #expect(h.store.rows.count == 2)
    h.store.toggleMute("com.other.zoom")
    let desired = await lastDesired(h)
    #expect(desired.filter(\.muted).map(\.app.id) == ["com.other.zoom"])
    #expect(desired.count == 2)
    #expect(h.store.rows.first { $0.id == "us.zoom.xos" }?.state.muted == false)
  }

  // MARK: Ordering, counter, expansion

  @Test func orderingAndCounterWithInactiveAppsShown() {
    let h = MixerHarness()
    h.settings.showInactiveApps = true
    h.start([
      h.process("Zoom", pid: 1, playing: false), h.process("Spotify", pid: 2, playing: true),
      h.process("Música", pid: 3, playing: false), h.process("Safari", pid: 4, playing: true),
    ])
    #expect(h.store.rows.map(\.app.name) == ["Safari", "Spotify", "Música", "Zoom"])
    #expect(h.store.playingCount == 2)
    h.store.handle(.processes([]))
    #expect(h.store.playingCount == 0)
  }

  @Test func counterTracksPlayingStateEvenWhileRowsLinger() {
    let h = MixerHarness()
    h.start([
      h.process("Spotify", pid: 2, playing: true), h.process("Safari", pid: 4, playing: true),
    ])
    #expect(h.store.playingCount == 2)
    h.store.handle(
      .processes([
        h.process("Spotify", pid: 2, playing: false), h.process("Safari", pid: 4, playing: true),
      ]))
    #expect(h.store.rows.count == 2)
    #expect(h.store.playingCount == 1)
  }

  @Test func expandedAppIsUniqueAndClearedWhenItsRowGoes() {
    let h = MixerHarness()
    h.start([
      h.process("Spotify", pid: 1, playing: true), h.process("Safari", pid: 2, playing: true),
    ])
    h.store.toggleExpanded("com.spotify.client")
    h.store.toggleExpanded("com.apple.Safari")
    #expect(h.store.expandedAppID == "com.apple.Safari")
    h.store.toggleExpanded("com.apple.Safari")
    #expect(h.store.expandedAppID == nil)
    h.store.toggleExpanded("com.apple.Safari")
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    #expect(h.store.expandedAppID == nil)
  }

  /// QA-BUG (Low): expanding an app that is not in the list sets `expandedAppID` to a ghost
  /// until the next rebuild.
  @Test func expandingAnUnknownAppIsIgnored() {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleExpanded("not.in.the.list")
    #expect(h.store.expandedAppID == nil)
  }

  // MARK: Master / system intents

  @Test func masterIntentsRejectGarbage() async {
    let h = MixerHarness()
    h.start([])
    h.store.setMasterVolume(.nan)
    h.store.setMasterVolume(.infinity)
    h.store.setMasterVolume(-3)
    h.store.setDefaultOutput("ghost")
    h.store.setDefaultOutput("")
    await h.settle()
    #expect(h.system.calls == [.masterVolume(0)])
    #expect(h.store.masterVolume == 0)
  }

  @Test func appThatRemainsAtDefaultNeverTouchesTheSystemVolume() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.2, for: "com.spotify.client")
    h.store.toggleMute("com.spotify.client")
    h.store.restoreOriginalAudio()
    await h.settle()
    #expect(h.system.calls.isEmpty)
  }
}

// MARK: - Helpers

/// A controller whose `reconcile` never returns until released, to prove that the panic button
/// does not queue behind it.
final class HangingController: AppAudioController, Sendable {
  func retry(appID: String) async {}
  func retryAll() async {}

  private struct State {
    var started = false
    var restored = false
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var reconcileStarted: Bool { state.withLock { $0.started } }
  var restoreCalled: Bool { state.withLock { $0.restored } }

  func release() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func reconcile(desired: [DesiredAppAudio]) async {
    state.withLock { $0.started = true }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = state.withLock { state -> Bool in
        if state.released { return true }
        state.waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func restoreAll() async { state.withLock { $0.restored = true } }
}
