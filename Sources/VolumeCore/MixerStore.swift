import Foundation
import Observation

/// Single source of truth of the mixer (SPEC 12.1): the apps, their volume, mute and output,
/// and the system output. The UI reads it and sends intents; services react to it.
@MainActor
@Observable
public final class MixerStore {
  /// Apps playing now or stopped less than `tapLingerPeriod` ago, and apps the user controls
  /// (volume, mute or output changed) while they have an audio process (SPEC 3.2, 4.1):
  /// playing first (a recent stop counts as playing), then by name.
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
  /// Apps whose tap failed or was removed by the safety watchdog; they play normally and the
  /// row says it could not be controlled (SPEC 4.6). Cleared by the next user action on the app.
  public private(set) var failedAppIDs: Set<String> = []

  /// How long an app keeps its tap after it stops playing, so pauses and track changes do not
  /// switch between the original sound and the tap (SPEC 4.2). After that the tap goes away
  /// and nothing keeps the output device running for an idle app.
  public static let tapLingerPeriod: Duration = .seconds(15)
  /// A "granted" this recent answers a new silence check without a new test tap, and after a
  /// "denied" from the silence guard the permission is checked again this often while
  /// something plays (SPEC 4.6).
  public static let permissionRecheckInterval: Duration = .seconds(30)
  /// Automatic checks after an ambiguous "denied" (see `recheckWhileDenied`).
  static let maxDeniedRechecks = 3

  @ObservationIgnored private let audioSystem: any AudioSystem
  @ObservationIgnored private let controller: any AppAudioController
  @ObservationIgnored private let appInfo: any AppInfoProvider
  @ObservationIgnored private let settings: SettingsModel
  @ObservationIgnored private let safety: SafetyPolicy
  @ObservationIgnored private let clock: AppClock
  @ObservationIgnored private let permission: PermissionMonitor
  @ObservationIgnored private var accessTask: Task<Void, Never>?
  @ObservationIgnored private var wantsTaps = false
  @ObservationIgnored private let ownPID: Int32?
  @ObservationIgnored private let epoch = EpochCounter()
  @ObservationIgnored private var panicTasks: [Task<Void, Never>] = []
  @ObservationIgnored private let controllerWork = OrderedWork()
  @ObservationIgnored private let systemWork = OrderedWork()

  @ObservationIgnored private var groups: [AudioApp] = []
  @ObservationIgnored private var states: [String: AppAudioState] = [:]
  @ObservationIgnored private var previouslyPlaying: Set<String> = []
  @ObservationIgnored private var lastDesired: [DesiredAppAudio]? = []
  /// Apps that stopped playing and keep their tap until `tapLingerPeriod` passes.
  @ObservationIgnored private var lingerTimers: [String: Task<Void, Never>] = [:]
  /// Idle apps the user just set back to 100%: the row stays `tapLingerPeriod` more, so it does
  /// not vanish under the pointer while the slider is dragged (no tap: only the row).
  @ObservationIgnored private var releaseTimers: [String: Task<Void, Never>] = [:]
  /// After "Restaurar áudio original" no app is tapped until the user changes one again.
  @ObservationIgnored private var tapsSuspended = false
  /// Apps whose output format cannot be controlled while the user had not adjusted them: they
  /// play natively without a warning until the user adjusts them (SPEC 4.2, 4.6).
  @ObservationIgnored private var quietFailures: Set<String> = []
  /// Running while a silence check's "granted" can still be reused.
  @ObservationIgnored private var recentGrant: Task<Void, Never>?
  /// True after an ambiguous "denied": from the silence guard, or from a check the user did not
  /// ask for while the permission was confirmed on this Mac (a silent stream gives zeros too).
  /// The taps are off (fail open) but the popover does not change (SPEC 3.2, 4.6).
  @ObservationIgnored private var ambiguousDenial = false
  /// A check proved the permission was not given (SPEC 3.2, cases 2 and 3).
  private var provenDenial = false
  /// The user clicked "Permitir…" in this session (SPEC 3.2, case 1).
  private var askedForAccess = false
  /// "Permitir…" could not conclude: the check runs again when something plays.
  @ObservationIgnored private var checkWhenPlaying = false
  /// The last check started by "Permitir…", the popover opening or a sound that starts.
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  /// Automatic checks after an ambiguous denial (periodic and "sound returned" share the
  /// budget). Only a "granted" from "Permitir…" resets it, so an automatic "granted" followed
  /// by a new silence-guard denial cannot repeat forever (SPEC 4.6).
  @ObservationIgnored private var automaticChecks = 0
  /// Running while a "denied" from the silence guard is checked again periodically.
  @ObservationIgnored private var deniedRechecks: Task<Void, Never>?
  /// Master volume not yet written to the system, and whether a writer is queued. Dragging
  /// the slider produces many values; only the newest one is written.
  @ObservationIgnored private var pendingMasterVolume: Double?
  @ObservationIgnored private var masterWriterQueued = false
  /// Newest desired audio not yet sent to the controller, and whether a sender is queued.
  @ObservationIgnored private var pendingReconcile: (list: [DesiredAppAudio], generation: Int)?
  @ObservationIgnored private var reconcileQueued = false
  /// Identifies the sender that may take `pendingReconcile`: a retry queued after it starts a
  /// new one, so the retry always runs before the reconcile that follows it.
  @ObservationIgnored private var reconcileSender = 0

  /// Creates the store. Nothing happens until `run()` or `handle(_:)`.
  public init(
    audioSystem: any AudioSystem, controller: any AppAudioController,
    appInfo: any AppInfoProvider, settings: SettingsModel, safety: SafetyPolicy, clock: AppClock,
    permission: PermissionMonitor, ownPID: Int32? = nil
  ) {
    self.permission = permission
    self.ownPID = ownPID
    self.audioSystem = audioSystem
    self.controller = controller
    self.appInfo = appInfo
    self.settings = settings
    self.safety = safety
    self.clock = clock
    settings.onChange { [weak self] in self?.rebuild() }
    let previous = permission.onGranted
    permission.onGranted = { [weak self] in
      previous()
      self?.permissionGranted()
    }
  }

  // MARK: Derived state

  /// True when the popover shows the "no permission" notice: only when the permission was
  /// proven not given (SPEC 3.2): never confirmed on this Mac and "Permitir…" not clicked yet,
  /// or a check proved it denied. Never because of silence, nothing playing, an inconclusive
  /// check or the silence guard.
  public var showsPermissionNotice: Bool {
    provenDenial
      || (permission.status == .notDetermined && !settings.audioPermissionConfirmed
        && !askedForAccess)
  }
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
      updatePlayback()
    case .devices(let list):
      var seen: Set<String> = []
      devices = list.filter { !$0.uid.isEmpty && seen.insert($0.uid).inserted }
    case .defaultOutput(let uid):
      defaultOutputUID = uid.map { TextSanitizer.clean($0) }.flatMap { $0.isEmpty ? nil : $0 }
    case .master(let state):
      // While our own writes are in flight the system echoes older values; the slider keeps
      // following the user and the last echo, after the writes, brings the real value.
      if !masterWriterQueued { masterVolume = state.volume }
      masterMuted = state.isMuted
    }
    rebuild()
  }

  /// A tap carried only digital silence for 120 s of output time (SPEC 4.6): a voice call
  /// nobody talks in, a browser with a silent stream, or a permission revoked while the Volume
  /// runs (which would leave every tapped app mute). Checks the permission by signal (a test tap
  /// that does not change the sound); a "granted" from the last `permissionRecheckInterval` is
  /// reused only when `mayReuseRecentGrant` (the same silence was already checked; never for
  /// the first silence after real sound, which is how a revocation looks). Denied: every tap is
  /// removed at once and the original sound returns, without changing the popover (the list
  /// stays, no notice) and without touching the stored mark: the denial is ambiguous (a silent
  /// stream may be the only player), so the permission is checked again while something plays.
  /// At most one check runs at a time (`PermissionMonitor`); the caller checks again later.
  public func checkSilentTap(mayReuseRecentGrant: Bool = false) async {
    guard !(mayReuseRecentGrant && recentGrant != nil) else { return }
    switch await permission.refresh(onlyIfDenied: false) {
    case .granted: rememberGrant()
    case .denied: noteAmbiguousDenial()
    case .notDetermined, nil: break
    }
  }

  /// Fail open without changing the popover, and check again while something plays.
  private func noteAmbiguousDenial() {
    ambiguousDenial = true
    recheckWhileDenied()
    rebuild()
  }

  /// The permission was found granted (by any check): it is remembered and failed apps get a
  /// new attempt. The automatic budget is left alone (see `automaticChecks`).
  private func permissionGranted() {
    ambiguousDenial = false
    provenDenial = false
    checkWhenPlaying = false
    settings.audioPermissionConfirmed = true
    retryAll()
  }

  private func rememberGrant() {
    recentGrant = Task { [weak self, clock] in
      try? await clock.sleep(for: MixerStore.permissionRecheckInterval)
      self?.recentGrant = nil
    }
  }

  /// After an ambiguous "denied" (`ambiguousDenial`): every
  /// `permissionRecheckInterval`, while something plays, checks again; a "granted" brings the
  /// taps back (`onGranted`). Together with the check when sound starts again
  /// (`updatePlayback`), at most `maxDeniedRechecks` automatic checks run, so a permission
  /// reset in System Settings cannot make them show the system prompt again and again (SPEC 5:
  /// the prompt follows a user action). After that, opening the popover (`onlyIfDenied`) takes
  /// over.
  private func recheckWhileDenied() {
    guard deniedRechecks == nil else { return }
    deniedRechecks = Task { [weak self, clock] in
      while true {
        do { try await clock.sleep(for: MixerStore.permissionRecheckInterval) } catch { return }
        guard let self, ambiguousDenial, permission.status == .denied,
          settings.audioPermissionConfirmed, automaticChecks < MixerStore.maxDeniedRechecks
        else { break }
        if groups.contains(where: \.isPlaying) { await runAutomaticCheck() }
      }
      self?.deniedRechecks = nil
    }
  }

  /// The one automatic check after an ambiguous denial; it spends the shared budget, which is
  /// what limits the checks (the "confirmed before" mark cannot tell a reset apart).
  private func runAutomaticCheck() async {
    guard ambiguousDenial, permission.status == .denied,
      automaticChecks < MixerStore.maxDeniedRechecks
    else { return }
    automaticChecks += 1
    record(await permission.refresh(onlyIfDenied: false), fromAllow: false)
  }

  /// Records that the controller could not (or can no longer) control `appID` (SPEC 4.6). With
  /// `quietIfUntouched`, an app the user has not adjusted shows no warning: it plays natively,
  /// as it would without the Volume, until the user adjusts it.
  public func controlFailed(_ appID: String, quietIfUntouched: Bool = false) {
    guard groups.contains(where: { $0.id == appID }) else { return }
    if quietIfUntouched, states[appID] ?? .default == .default {
      quietFailures.insert(appID)
    } else {
      failedAppIDs.insert(appID)
    }
  }

  /// Allows a new attempt for every failed app, for example after the permission was granted.
  public func retryAll() {
    failedAppIDs = []
    quietFailures = []
    lastDesired = nil
    startNewReconcileSender()
    controllerWork.enqueue { [controller] in await controller.retryAll() }
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
    pendingMasterVolume = clamped
    guard !masterWriterQueued else { return }
    masterWriterQueued = true
    systemWork.enqueue { [weak self] in
      while let next = await self?.takePendingMasterVolume() {
        await self?.audioSystem.setMasterVolume(next)
      }
    }
  }

  /// The newest master volume to write, or `nil` (and the writer ends) when there is none.
  private func takePendingMasterVolume() -> Double? {
    defer { pendingMasterVolume = nil }
    if pendingMasterVolume == nil { masterWriterQueued = false }
    return pendingMasterVolume
  }

  /// Asks the audio system to re-read its state (the popover just opened).
  public func refreshAudioSystem() {
    systemWork.enqueue { [audioSystem] in await audioSystem.refresh() }
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
  /// called at once, not queued behind pending `reconcile` calls, which are discarded. No app is
  /// tapped again until the user changes one (otherwise "always controlled" would put every tap
  /// back at once).
  public func restoreOriginalAudio() {
    states = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, AppAudioState.default) })
    failedAppIDs = []
    quietFailures = []
    // Panic removes every tap now and keeps them off until the user acts again.
    for timer in lingerTimers.values { timer.cancel() }
    lingerTimers = [:]
    for timer in releaseTimers.values { timer.cancel() }
    releaseTimers = [:]
    tapsSuspended = true
    settings.forgetAll()
    lastDesired = nil
    epoch.advance()
    panicTasks.append(Task { [controller] in await controller.restoreAll() })
    rebuild()
  }

  // MARK: Internals

  /// Waits until every queued call to the services has finished.
  func settle() async {
    await accessTask?.value
    await checkTask?.value
    await systemWork.settle()
    await controllerWork.settle()
    for task in panicTasks { await task.value }
  }

  private func update(_ appID: String, _ change: (inout AppAudioState) -> Void) {
    guard var state = states[appID] else { return }
    if failedAppIDs.remove(appID) != nil {
      lastDesired = nil
      startNewReconcileSender()
      controllerWork.enqueue { [controller] in await controller.retry(appID: appID) }
    }
    let wasControlled = state != .default
    change(&state)
    states[appID] = state
    if wasControlled, state == .default, !isPlaying(appID), lingerTimers[appID] == nil {
      keepRowAfterRelease(appID)
    }
    // The control already failed quietly: the adjustment cannot apply, so say so now.
    if quietFailures.remove(appID) != nil { failedAppIDs.insert(appID) }
    tapsSuspended = false
    defer { confirmAccessIfNeeded(userAction: true) }
    if settings.rememberVolumes, let bundleID = groups.first(where: { $0.id == appID })?.bundleID {
      if state == .default {
        settings.forget(bundleID)
      } else {
        settings.remember(state, for: bundleID)
      }
    }
    rebuild()
  }

  private func keepRowAfterRelease(_ id: String) {
    releaseTimers[id]?.cancel()
    releaseTimers[id] = Task { [weak self, clock] in
      do { try await clock.sleep(for: MixerStore.tapLingerPeriod) } catch { return }
      guard self?.releaseTimers.removeValue(forKey: id) != nil else { return }
      self?.rebuild()
    }
  }

  /// No tap exists until a signal check confirmed the permission in this session (SPEC 4.6).
  /// The check runs after a user action, or by itself when the permission was confirmed on
  /// this Mac before and a remembered app is playing (the user already decided, so the system
  /// shows no prompt). An indeterminate result leaves it pending until the next action or
  /// reconciliation.
  private func confirmAccessIfNeeded(userAction: Bool = false) {
    guard wantsTaps, permission.status != .granted, accessTask == nil else { return }
    accessTask = Task { [weak self] in
      guard let self else { return }
      let result = await permission.refresh(onlyIfDenied: false, userAction: userAction)
      accessTask = nil
      record(result, fromAllow: false)
    }
  }

  /// "Permitir…" (welcome window and popover): the user asks for the permission, which shows
  /// the system prompt when the user has not decided yet. Returns the result, or `nil` when
  /// another check was already running.
  public func requestAccess() async -> AudioPermissionStatus? {
    askedForAccess = true
    let result = await permission.refresh(onlyIfDenied: false, userAction: true)
    record(result, fromAllow: true)
    return result
  }

  /// "Permitir…" of the popover's notice. After a denial the system no longer asks, so it
  /// opens System Settings, hides the notice and checks again when something plays (SPEC 3.2,
  /// 5); otherwise it runs the check of `requestAccess()`.
  public func allowAccess() {
    guard permission.status == .denied else {
      startCheck { _ = await $0.requestAccess() }
      return
    }
    askedForAccess = true
    provenDenial = false
    checkWhenPlaying = true
    permission.openPrivacySettings()
  }

  /// The popover opened: re-reads the audio system and, when the permission is denied, checks
  /// again (a grant made later in System Settings is found without restarting, SPEC 5). Never
  /// shows the system prompt by itself.
  public func popoverOpened() {
    refreshAudioSystem()
    // After an inconclusive "Permitir…", something playing now is when its check runs.
    if checkWhenPlaying && groups.contains(where: \.isPlaying) {
      startCheck { await $0.runAllowFollowUp() }
    } else {
      startCheck { $0.record(await $0.permission.refresh(onlyIfDenied: true), fromAllow: false) }
    }
  }

  /// Runs one check in the background. The previous one is cancelled first (`PermissionMonitor`
  /// runs one at a time anyway); `settle()` waits for the last.
  private func startCheck(_ check: @escaping @MainActor (MixerStore) async -> Void) {
    checkTask?.cancel()
    checkTask = Task { [weak self] in
      guard let self else { return }
      await check(self)
    }
  }

  /// The one check after an inconclusive "Permitir…", when something plays: it runs at most
  /// once per click, and only a conclusive result changes anything (SPEC 3.2).
  private func runAllowFollowUp() async {
    guard checkWhenPlaying else { return }
    checkWhenPlaying = false
    let result = await permission.refresh(onlyIfDenied: false)
    if result == .granted || result == .denied { record(result, fromAllow: true) }
  }

  /// What a check result changes (SPEC 3.2, 4.6, 5). `fromAllow`: "Permitir…" or its
  /// follow-up. Only those may clear the stored mark or reset the automatic budget; with the
  /// mark, other checks never show the notice.
  private func record(_ result: AudioPermissionStatus?, fromAllow: Bool) {
    switch result {
    case .granted:
      if fromAllow { automaticChecks = 0 }
      permissionGranted()
    case .denied where fromAllow:
      ambiguousDenial = false
      checkWhenPlaying = false
      provenDenial = true
      settings.audioPermissionConfirmed = false
      rebuild()
    case .denied where settings.audioPermissionConfirmed || ambiguousDenial:
      noteAmbiguousDenial()
    case .denied:
      provenDenial = true
      rebuild()
    case .notDetermined, nil:
      // "Permitir…" could not conclude: hide the notice and check when something plays.
      if fromAllow {
        provenDenial = false
        checkWhenPlaying = true
      }
    }
  }

  private func isPlaying(_ appID: String) -> Bool {
    groups.contains { $0.id == appID && $0.isPlaying }
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

  /// Keeps the tap of an app that stopped for `tapLingerPeriod`, and runs the pending
  /// permission checks when an app starts playing (SPEC 3.2, 4.6).
  private func updatePlayback() {
    let playing = Set(groups.filter(\.isPlaying).map(\.id))
    let present = Set(groups.map(\.id))
    for id in lingerTimers.keys where playing.contains(id) || !present.contains(id) {
      lingerTimers.removeValue(forKey: id)?.cancel()
    }
    for id in releaseTimers.keys where playing.contains(id) || !present.contains(id) {
      releaseTimers.removeValue(forKey: id)?.cancel()
    }
    for id in previouslyPlaying.subtracting(playing)
    where present.contains(id) && lingerTimers[id] == nil {
      lingerTimers[id] = Task { [weak self, clock] in
        do { try await clock.sleep(for: MixerStore.tapLingerPeriod) } catch { return }
        self?.lingerExpired(id)
      }
    }
    // A sound that starts is the signal for the pending check: after an inconclusive
    // "Permitir…", or after an ambiguous denial (SPEC 3.2, 4.6).
    if !playing.subtracting(previouslyPlaying).isEmpty {
      if checkWhenPlaying {
        startCheck { await $0.runAllowFollowUp() }
      } else if ambiguousDenial {
        startCheck { await $0.runAutomaticCheck() }
      }
    }
    previouslyPlaying = playing
  }

  private func lingerExpired(_ id: String) {
    guard lingerTimers.removeValue(forKey: id) != nil else { return }
    rebuild()
  }

  private func rebuild() {
    let active = Set(groups.filter { $0.isPlaying || lingerTimers[$0.id] != nil }.map(\.id))
    // Playing (or stopped < 15 s), or controlled by the user (SPEC 3.2 item 4).
    let listed = groups.filter {
      active.contains($0.id) || states[$0.id] ?? .default != .default
        || releaseTimers[$0.id] != nil
    }
    rows = listed.map(makeRow).sorted {
      Self.isOrderedBefore($0, $1, active: active)
    }
    failedAppIDs.formIntersection(groups.map(\.id))
    quietFailures.formIntersection(groups.map(\.id))
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

  /// Playing (`active`) first, then by name, so a row does not jump between tracks or pauses.
  private static func isOrderedBefore(
    _ lhs: MixerRow, _ rhs: MixerRow, active: Set<String>
  ) -> Bool {
    let left = active.contains(lhs.id)
    if left != active.contains(rhs.id) { return left }
    switch lhs.app.name.localizedStandardCompare(rhs.app.name) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return lhs.id < rhs.id
    }
  }

  /// Computes the desired audio and sends it to the controller only if it changed. Every app
  /// that plays, or stopped less than `tapLingerPeriod` ago, has an entry, also at 100% (gain
  /// exactly 1); none while taps are suspended by a restore (SPEC 4.2).
  private func reconcile() {
    var desired: [DesiredAppAudio] = []
    for app in groups where !app.pids.isEmpty {
      let state = states[app.id] ?? .default
      guard
        let route = RoutingPolicy.resolve(
          preferredUID: state.preferredOutputUID, devices: devices, defaultUID: defaultOutputUID)
      else { continue }
      let gain = VolumeCurve.gain(forVolume: state.volume)
      // Always controlled while playing, even at 100% (gain exactly 1): a volume change then
      // only moves the gain and never switches between the original sound and the tap.
      guard !tapsSuspended, app.isPlaying || lingerTimers[app.id] != nil else { continue }
      desired.append(
        DesiredAppAudio(
          app: ControlledApp(app), gain: gain, muted: state.muted, targetDeviceUID: route.deviceUID)
      )
    }
    wantsTaps = !desired.isEmpty
    // After an ambiguous denial, `runAutomaticCheck` does the checking.
    if settings.audioPermissionConfirmed, !ambiguousDenial,
      desired.contains(where: { isPlaying($0.app.id) })
    {
      confirmAccessIfNeeded()
    }
    let allowed = permission.status == .granted ? desired : []
    guard allowed != lastDesired else { return }
    lastDesired = allowed
    pendingReconcile = (allowed, epoch.current)
    guard !reconcileQueued else { return }
    reconcileQueued = true
    let sender = reconcileSender
    controllerWork.enqueue { [weak self, controller, epoch] in
      while let next = await self?.takePendingReconcile(sender: sender) {
        guard epoch.current == next.generation else { continue }
        await controller.reconcile(desired: next.list)
      }
    }
  }

  private func startNewReconcileSender() {
    reconcileSender += 1
    reconcileQueued = false
  }

  /// The newest desired audio to send, or `nil` (and the sender ends) when there is none.
  private func takePendingReconcile(sender: Int) -> (list: [DesiredAppAudio], generation: Int)? {
    guard sender == reconcileSender else { return nil }
    defer { pendingReconcile = nil }
    if pendingReconcile == nil { reconcileQueued = false }
    return pendingReconcile
  }
}
