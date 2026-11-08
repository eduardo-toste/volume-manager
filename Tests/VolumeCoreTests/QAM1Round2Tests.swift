import Foundation
import Synchronization
import Testing

@testable import VolumeCore

/// Records every call in order. The first `reconcile` can be held until `release()`.
final class OrderedSpyController: AppAudioController, Sendable {
  func retry(appID: String) async {}
  func retryAll() async {}

  enum Call: Sendable, Equatable {
    case reconcile([DesiredAppAudio])
    case restoreAll
  }

  private struct State {
    var calls: [Call] = []
    var holdFirst: Bool
    var held: CheckedContinuation<Void, Never>?
    var firstStarted = false
  }

  private let state: Mutex<State>

  init(holdFirstReconcile: Bool) { state = Mutex(State(holdFirst: holdFirstReconcile)) }

  var calls: [Call] { state.withLock { $0.calls } }
  var firstStarted: Bool { state.withLock { $0.firstStarted } }

  func release() {
    let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.holdFirst = false
      defer { state.held = nil }
      return state.held
    }
    waiter?.resume()
  }

  func reconcile(desired: [DesiredAppAudio]) async {
    let shouldHold = state.withLock { state -> Bool in
      state.calls.append(.reconcile(desired))
      if state.holdFirst && !state.firstStarted {
        state.firstStarted = true
        return true
      }
      return false
    }
    guard shouldHold else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = state.withLock { state -> Bool in
        if !state.holdFirst { return true }
        state.held = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func restoreAll() async { state.withLock { $0.calls.append(.restoreAll) } }
}

@MainActor
@Suite("QA M1 round 2: panic ordering")
struct QAPanicOrderingTests {
  private func makeStore(_ controller: OrderedSpyController) -> (MixerStore, FakeClock) {
    let clock = FakeClock()
    let preferences = InMemoryPreferencesStore()
    let settings = SettingsModel(store: preferences, clock: clock)
    let store = MixerStore(
      audioSystem: FakeAudioSystem(), controller: controller, appInfo: FakeAppInfoProvider(),
      settings: settings, safety: SafetyPolicy(store: preferences, clock: clock), clock: clock,
      permission: grantedPermission())
    store.handle(.devices([MixerHarness.speakers, MixerHarness.airpods]))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(
      .processes([AudioProcessInfo(pid: 1, bundleID: "com.spotify.client", isRunningOutput: true)]))
    return (store, clock)
  }

  private let spotify = "com.spotify.client"

  @Test func staleQueuedReconcilesNeverReapplyTapsAfterPanic() async {
    let controller = OrderedSpyController(holdFirstReconcile: true)
    let (store, _) = makeStore(controller)
    store.setVolume(0.5, for: spotify)
    #expect(await eventually { controller.firstStarted })
    store.setVolume(0.3, for: spotify)
    store.toggleMute(spotify)
    store.route(spotify, to: "airpods")
    store.restoreOriginalAudio()
    #expect(await eventually { controller.calls.contains(.restoreAll) })
    controller.release()
    await store.settle()
    let calls = controller.calls
    let restoreIndex = calls.firstIndex(of: .restoreAll) ?? 0
    for call in calls[(restoreIndex + 1)...] {
      if case .reconcile(let desired) = call { #expect(desired.isEmpty, "stale taps: \(desired)") }
    }
    let queuedBeforePanic = calls[1..<restoreIndex]
    #expect(queuedBeforePanic.isEmpty, "queued reconciles were not discarded")
    #expect(calls.last == .reconcile([]))
    #expect(store.rows.first?.state == .default)
  }

  @Test func changesAfterPanicAreAppliedAfterRestoreAll() async {
    let controller = OrderedSpyController(holdFirstReconcile: false)
    let (store, _) = makeStore(controller)
    store.setVolume(0.5, for: spotify)
    store.restoreOriginalAudio()
    store.setVolume(0.4, for: spotify)
    await store.settle()
    let calls = controller.calls
    let restore = calls.firstIndex(of: .restoreAll)
    #expect(restore != nil)
    let last = calls.last
    if case .reconcile(let desired) = last {
      #expect(desired.count == 1 && desired[0].gain == VolumeCurve.gain(forVolume: 0.4))
    } else {
      Issue.record("last call must be the post-panic reconcile, got \(String(describing: last))")
    }
    if let restore, let finalIndex = calls.indices.last {
      #expect(restore < finalIndex)
    }
  }

  @Test func repeatedPanicsAndPanicWithoutAppsAreHarmless() async {
    let controller = OrderedSpyController(holdFirstReconcile: false)
    let (store, _) = makeStore(controller)
    store.setVolume(0.5, for: spotify)
    for _ in 0..<5 { store.restoreOriginalAudio() }
    store.handle(.processes([]))
    store.restoreOriginalAudio()
    await store.settle()
    #expect(controller.calls.filter { $0 == .restoreAll }.count == 6)
    #expect(controller.calls.last != nil)
    if case .reconcile(let desired) = controller.calls.last { #expect(desired.isEmpty) }
  }

  @Test func eventsArrivingAroundPanicNeverResurrectOldState() async {
    let controller = OrderedSpyController(holdFirstReconcile: false)
    let (store, _) = makeStore(controller)
    store.toggleMute(spotify)
    store.restoreOriginalAudio()
    store.handle(.devices([MixerHarness.speakers]))
    store.handle(.defaultOutput(uid: "airpods"))
    store.handle(.defaultOutput(uid: "speakers"))
    store.handle(
      .processes([
        AudioProcessInfo(pid: 1, bundleID: "com.spotify.client", isRunningOutput: false),
        AudioProcessInfo(pid: 7, bundleID: "com.spotify.client", isRunningOutput: true),
      ]))
    await store.settle()
    if case .reconcile(let desired) = controller.calls.last { #expect(desired.isEmpty) }
    #expect(store.rows.first?.state == .default)
  }

  @Test func panicForgetsEverythingRememberedEvenForAppsNeverSeen() {
    let h = MixerHarness(preferences: [
      "rememberedApps": ["com.never.seen": ["volume": 0.1, "muted": true]]
    ])
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.toggleMute("com.spotify.client")
    h.store.restoreOriginalAudio()
    #expect(h.settings.rememberedApps.isEmpty)
    h.store.handle(
      .processes([AudioProcessInfo(pid: 9, bundleID: "com.never.seen", isRunningOutput: true)]))
    #expect(h.store.rows.first { $0.id == "com.never.seen" }?.state == .default)
  }
}

@MainActor
@Suite("QA M1 round 2: idempotence and exclusion")
struct QARound2StoreTests {
  @Test func playPauseNameChangeAndIdleTransitionsDoNotResend() async {
    let h = MixerHarness()
    h.start([h.process("Spotify", pid: 1, playing: true)])
    h.store.setVolume(0.5, for: "com.spotify.client")
    await h.settle()
    let baseline = h.controller.reconcileCalls.count
    for playing in [false, true, false, true, false] {
      h.store.handle(.processes([h.process("Spotify", pid: 1, playing: playing)]))
    }
    h.info.setApp("/Applications/Spotify.app", name: "Renamed", bundleID: "com.spotify.client")
    h.store.handle(.processes([h.process("Spotify", pid: 1, playing: true)]))
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline)
    h.store.handle(
      .processes([
        h.process("Spotify", pid: 1, playing: true), h.process("Spotify", pid: 3, playing: false),
      ]))
    await h.settle()
    #expect(h.controller.reconcileCalls.count == baseline + 1)
  }

  @Test func ownPIDIsExcludedThroughTheStore() {
    let clock = FakeClock()
    let preferences = InMemoryPreferencesStore()
    let info = FakeAppInfoProvider()
    info.setApp("/Applications/Spotify.app", name: "Spotify", bundleID: "com.spotify.client")
    let store = MixerStore(
      audioSystem: FakeAudioSystem(), controller: SpyAppAudioController(), appInfo: info,
      settings: SettingsModel(store: preferences, clock: clock),
      safety: SafetyPolicy(store: preferences, clock: clock), clock: clock,
      permission: grantedPermission(), ownPID: 4242)
    store.handle(
      .processes([
        AudioProcessInfo(pid: 4242, bundleID: "com.apple.Safari", isRunningOutput: true),
        AudioProcessInfo(
          pid: 5, bundleID: "com.apple.WebKit.GPU", responsiblePID: 4242, isRunningOutput: true),
        AudioProcessInfo(
          pid: 1, executablePath: "/Applications/Spotify.app/Contents/MacOS/S",
          isRunningOutput: true),
      ]))
    #expect(store.rows.map(\.id) == ["com.spotify.client"])
  }

  @Test func ownPIDDoesNotHideOtherProcessesOfTheSameApp() {
    let info = FakeAppInfoProvider()
    info.setApp("/Applications/Spotify.app", name: "Spotify", bundleID: "com.spotify.client")
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Applications/Spotify.app/Contents/MacOS/S"),
      AudioProcessInfo(pid: 2, executablePath: "/Applications/Spotify.app/Contents/MacOS/S"),
    ]
    let apps = ProcessGrouping.group(processes, info: info, excludedPID: 1)
    #expect(apps.first?.pids == [2])
  }

  @Test func volumePathIsExcludedWithoutAnyPlistOrBundleID() {
    let info = FakeAppInfoProvider()
    let processes = [
      AudioProcessInfo(pid: 1, executablePath: "/Users/me/Build/Volume.app/Contents/MacOS/V"),
      AudioProcessInfo(
        pid: 2,
        executablePath: "/Applications/Volume.app/Contents/Frameworks/x/Helper.app/Contents/MacOS/h"
      ),
      AudioProcessInfo(pid: 3, executablePath: "/Applications/Other.app/Contents/MacOS/o"),
    ]
    let apps = ProcessGrouping.group(processes, info: info)
    #expect(apps.map(\.pids) == [[3]])
  }
}

@Suite("QA M1 round 2: sanitizer by category")
struct QASanitizerCategoryTests {
  @Test func noControlOrFormatScalarSurvivesExceptTheTwoJoiners() {
    var offenders: [UInt32] = []
    var value: UInt32 = 0
    while value <= 0x10FFFF {
      defer { value += 1 }
      guard let unicode = Unicode.Scalar(value) else { continue }
      let cleaned = TextSanitizer.clean("a" + String(Character(unicode)) + "b")
      for result in cleaned.unicodeScalars {
        let category = result.properties.generalCategory
        let tag = (0xE0000...0xE007F).contains(result.value)
        if (category == .control || category == .format || tag)
          && result.value != 0x200C && result.value != 0x200D
        {
          offenders.append(value)
        }
      }
      if value == 0x200C || value == 0x200D { continue }
      if category(unicode) == .control || category(unicode) == .format {
        if cleaned != "ab" && cleaned != "a b" && !offenders.contains(value) {
          offenders.append(value)
        }
      }
    }
    #expect(offenders.isEmpty, "survivors: \(offenders.prefix(20).map { String($0, radix: 16) })")
  }

  private func category(_ scalar: Unicode.Scalar) -> Unicode.GeneralCategory {
    scalar.properties.generalCategory
  }

  @Test func joinerEdgeCases() {
    #expect(TextSanitizer.clean("\u{200C}") == "")
    #expect(TextSanitizer.clean("\u{200D}\u{200D}\u{200D}") == "")
    #expect(TextSanitizer.clean("a\u{200D}\u{200B}b") == "a\u{200D}b")
    #expect(TextSanitizer.clean("a\u{200D}\n\u{200D}b") == "a b")
    #expect(TextSanitizer.clean("a\u{200D}\u{202E}\u{200D}b") == "a\u{200D}b")
    #expect(TextSanitizer.clean("\u{202E}\u{200D}a") == "a")
  }

  @Test func joinerFloodIsBoundedFastAndNeverEndsWithAJoiner() {
    for unit in ["a\u{200D}", "a\u{200C}\u{200D}", "\u{200D}", "👨\u{200D}"] {
      let huge = String(repeating: unit, count: 5_000_000)
      let start = ContinuousClock.now
      let cleaned = TextSanitizer.clean(huge)
      #expect(ContinuousClock.now - start < .seconds(1))
      #expect(cleaned.count <= TextSanitizer.maxLength)
      #expect(cleaned.utf8.count <= TextSanitizer.maxLength * 4)
      if let last = cleaned.unicodeScalars.last {
        #expect(last.value != 0x200D && last.value != 0x200C)
      }
    }
  }

  @Test func neverTwoJoinersInARow() {
    let cleaned = TextSanitizer.clean("a\u{200D}\u{200C}\u{200D}b\u{200C}\u{200C}c")
    let scalars = Array(cleaned.unicodeScalars)
    for pair in zip(scalars, scalars.dropFirst()) {
      #expect(
        !((pair.0.value == 0x200C || pair.0.value == 0x200D)
          && (pair.1.value == 0x200C || pair.1.value == 0x200D)))
    }
  }
}
