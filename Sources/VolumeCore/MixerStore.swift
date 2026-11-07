import Foundation
import Observation

/// Single source of truth of the mixer (SPEC 12.1): the apps, their volume, mute and output,
/// and the system output. The UI reads it and sends intents; services react to it.
@MainActor
@Observable
public final class MixerStore {
  /// Apps shown in the list: playing first, then by name.
  public private(set) var rows: [MixerRow] = []
  /// Connected output devices.
  public private(set) var devices: [OutputDevice] = []
  /// UID of the system default output.
  public private(set) var defaultOutputUID: String?
  /// Volume of the default output.
  public private(set) var masterVolume = 1.0
  /// Mute of the default output.
  public private(set) var masterMuted = false
  /// The one row that is expanded, if any.
  public private(set) var expandedAppID: String?

  /// How long an app that stopped playing stays in the list (SPEC 4.1).
  public static let gracePeriod: Duration = .seconds(5)

  @ObservationIgnored private let audioSystem: any AudioSystem
  @ObservationIgnored private let controller: any AppAudioController
  @ObservationIgnored private let appInfo: any AppInfoProvider
  @ObservationIgnored private let settings: SettingsModel
  @ObservationIgnored private let safety: SafetyPolicy
  @ObservationIgnored private let clock: AppClock
  @ObservationIgnored private let ownPID: Int32?
  @ObservationIgnored private let epoch = EpochCounter()
  @ObservationIgnored private var panicTasks: [Task<Void, Never>] = []
  @ObservationIgnored private let controllerWork = OrderedWork()
  @ObservationIgnored private let systemWork = OrderedWork()

  @ObservationIgnored private var groups: [AudioApp] = []
  @ObservationIgnored private var states: [String: AppAudioState] = [:]
  @ObservationIgnored private var graceTimers: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var previouslyPlaying: Set<String> = []
  @ObservationIgnored private var lastDesired: [DesiredAppAudio]? = []

  /// Creates the store. Nothing happens until `run()` or `handle(_:)`.
  public init(
    audioSystem: any AudioSystem, controller: any AppAudioController,
    appInfo: any AppInfoProvider, settings: SettingsModel, safety: SafetyPolicy, clock: AppClock,
    ownPID: Int32? = nil
  ) {
    self.ownPID = ownPID
    self.audioSystem = audioSystem
    self.controller = controller
    self.appInfo = appInfo
    self.settings = settings
    self.safety = safety
    self.clock = clock
    settings.onChange { [weak self] in self?.rebuild() }
  }

  // MARK: Derived state

  /// Number of apps playing now ("N reproduzindo").
  public var playingCount: Int { rows.filter(\.app.isPlaying).count }
  /// The default output device, if known.
  public var defaultOutput: OutputDevice? { devices.first { $0.uid == defaultOutputUID } }
  /// False when the default output has no software volume, so the master slider is disabled.
  public var masterHasVolumeControl: Bool { defaultOutput?.hasVolumeControl ?? true }
  /// True while remembered settings are not being applied (SPEC 4.6).
  public var isSafeMode: Bool { safety.isSafeMode }

  // MARK: Events

  /// Reads the current state, then applies every change until the stream ends.
  public func run() async {
    let stream = audioSystem.events()
    let snapshot = await audioSystem.currentState()
    handle(.devices(snapshot.devices))
    handle(.defaultOutput(uid: snapshot.defaultOutputUID))
    if let master = snapshot.master { handle(.master(master)) }
    handle(.processes(snapshot.processes))
    for await event in stream { handle(event) }
  }

  /// Applies one change of the audio system.
  public func handle(_ event: AudioSystemEvent) {
    switch event {
    case .processes(let processes):
      groups = ProcessGrouping.group(processes, info: appInfo, excludedPID: ownPID)
      adoptNewApps()
      updateGraceTimers()
    case .devices(let list):
      var seen: Set<String> = []
      devices = list.filter { !$0.uid.isEmpty && seen.insert($0.uid).inserted }
    case .defaultOutput(let uid):
      defaultOutputUID = uid.map { TextSanitizer.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
    case .master(let state):
      masterVolume = state.volume
      masterMuted = state.isMuted
    }
    rebuild()
  }

  // MARK: Intents

  /// Sets the volume of an app. Invalid values are made safe (NaN becomes 100%).
  public func setVolume(_ volume: Double, for appID: String) {
    update(appID) { $0.volume = VolumeCurve.clampedVolume(volume) }
  }

  /// Mutes or unmutes an app. The slider keeps its value.
  public func toggleMute(_ appID: String) {
    update(appID) { $0.muted.toggle() }
  }

  /// Plays an app on the device with this UID, or on the system default when `uid` is `nil`.
  /// Unknown devices are ignored.
  public func route(_ appID: String, to uid: String?) {
    if let uid, !devices.contains(where: { $0.uid == uid }) { return }
    update(appID) { $0.preferredOutputUID = uid }
  }

  /// Sets the volume of the default output. Non-numeric values are ignored.
  public func setMasterVolume(_ volume: Double) {
    guard volume.isFinite else { return }
    let clamped = VolumeCurve.clampedVolume(volume)
    masterVolume = clamped
    systemWork.enqueue { [audioSystem] in await audioSystem.setMasterVolume(clamped) }
  }

  /// Mutes or unmutes the default output.
  public func toggleMasterMute() {
    masterMuted.toggle()
    let muted = masterMuted
    systemWork.enqueue { [audioSystem] in await audioSystem.setMasterMuted(muted) }
  }

  /// Makes a connected device the system default output. Unknown devices are ignored.
  public func setDefaultOutput(_ uid: String) {
    guard devices.contains(where: { $0.uid == uid }) else { return }
    systemWork.enqueue { [audioSystem] in await audioSystem.setDefaultOutput(uid: uid) }
  }

  /// Expands the row of `appID`, or collapses it if it already is. Only one row is expanded.
  public func toggleExpanded(_ appID: String) {
    if expandedAppID == appID {
      expandedAppID = nil
    } else if rows.contains(where: { $0.id == appID }) {
      expandedAppID = appID
    }
  }

  /// Panic button (SPEC 4.6), a clean slate: every app, listed or not, goes back to 100%, not
  /// muted, system default output; everything remembered is forgotten; and `restoreAll` is
  /// called at once, not queued behind pending `reconcile` calls, which are discarded.
  public func restoreOriginalAudio() {
    states = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, AppAudioState.default) })
    settings.forgetAll()
    lastDesired = nil
    epoch.advance()
    panicTasks.append(Task { [controller] in await controller.restoreAll() })
    rebuild()
  }

  // MARK: Internals

  /// Waits until every queued call to the services has finished.
  func settle() async {
    await systemWork.settle()
    await controllerWork.settle()
    for task in panicTasks { await task.value }
  }

  private func update(_ appID: String, _ change: (inout AppAudioState) -> Void) {
    guard var state = states[appID] else { return }
    change(&state)
    states[appID] = state
    if settings.rememberVolumes, let bundleID = groups.first(where: { $0.id == appID })?.bundleID {
      if state == .default {
        settings.forget(bundleID)
      } else {
        settings.remember(state, for: bundleID)
      }
    }
    rebuild()
  }

  private func adoptNewApps() {
    let applyRemembered = settings.rememberVolumes && !safety.isSafeMode
    for app in groups where states[app.id] == nil {
      if applyRemembered, let bundleID = app.bundleID,
        let record = settings.remembered(for: bundleID)
      {
        states[app.id] = record.state
      } else {
        states[app.id] = .default
      }
    }
  }

  private func updateGraceTimers() {
    let playing = Set(groups.filter(\.isPlaying).map(\.id))
    let present = Set(groups.map(\.id))
    for id in graceTimers.keys where playing.contains(id) || !present.contains(id) {
      graceTimers.removeValue(forKey: id)?.cancel()
    }
    for id in previouslyPlaying.subtracting(playing)
    where present.contains(id) && graceTimers[id] == nil {
      graceTimers[id] = Task { [weak self, clock] in
        do { try await clock.sleep(for: MixerStore.gracePeriod) } catch { return }
        self?.graceExpired(id)
      }
    }
    previouslyPlaying = playing
  }

  private func graceExpired(_ id: String) {
    guard graceTimers.removeValue(forKey: id) != nil else { return }
    rebuild()
  }

  private func rebuild() {
    let visible = groups.filter {
      settings.showInactiveApps || $0.isPlaying || graceTimers[$0.id] != nil
    }
    rows = visible.map(makeRow).sorted(by: Self.isOrderedBefore)
    if let expanded = expandedAppID, !rows.contains(where: { $0.id == expanded }) {
      expandedAppID = nil
    }
    reconcile()
  }

  private func makeRow(_ app: AudioApp) -> MixerRow {
    let state = states[app.id] ?? .default
    let route = RoutingPolicy.resolve(
      preferredUID: state.preferredOutputUID, devices: devices, defaultUID: defaultOutputUID)
    return MixerRow(
      app: app, state: state,
      device: route.flatMap { route in devices.first { $0.uid == route.deviceUID } },
      usesSystemDefault: route?.usesSystemDefault ?? true,
      savedDeviceMissing: RoutingPolicy.isPreferredDeviceMissing(
        preferredUID: state.preferredOutputUID, devices: devices))
  }

  private static func isOrderedBefore(_ lhs: MixerRow, _ rhs: MixerRow) -> Bool {
    if lhs.app.isPlaying != rhs.app.isPlaying { return lhs.app.isPlaying }
    switch lhs.app.name.localizedStandardCompare(rhs.app.name) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs.id < rhs.id
    }
  }

  /// Computes the desired audio and sends it to the controller only if it changed. Apps at
  /// 100%, not muted and on the default output get no entry, hence no tap (SPEC 4.2).
  private func reconcile() {
    var desired: [DesiredAppAudio] = []
    for app in groups where !app.pids.isEmpty {
      let state = states[app.id] ?? .default
      guard
        let route = RoutingPolicy.resolve(
          preferredUID: state.preferredOutputUID, devices: devices, defaultUID: defaultOutputUID)
      else { continue }
      let gain = VolumeCurve.gain(forVolume: state.volume)
      guard gain < 1 || state.muted || !route.usesSystemDefault else { continue }
      desired.append(
        DesiredAppAudio(
          app: ControlledApp(app), gain: gain, muted: state.muted, targetDeviceUID: route.deviceUID)
      )
    }
    guard desired != lastDesired else { return }
    lastDesired = desired
    let generation = epoch.current
    controllerWork.enqueue { [controller, epoch, desired] in
      guard epoch.current == generation else { return }
      await controller.reconcile(desired: desired)
    }
  }
}
