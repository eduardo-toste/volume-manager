import Foundation
import Synchronization
import VolumeCore

/// Counts `restoreAll` calls; work started under an older count is obsolete.
final class Generation: Sendable {
  private let value = Atomic<Int>(0)
  var current: Int { value.load(ordering: .acquiring) }
  /// Starts a new generation and returns it.
  @discardableResult
  func advance() -> Int { value.add(1, ordering: .acquiringAndReleasing).newValue }
}

/// The real `AppAudioController`: one tap + private aggregate device + IOProc per controlled
/// app (SPEC 4.2), reconciled declaratively and idempotently (SPEC 12.1).
///
/// Safety rules (SPEC 4.6, CLAUDE.md 9): every failure ends with the tap destroyed so the app
/// plays normally again; a failed app is not retried in a loop; the watchdog runs only while
/// taps exist; `restoreAll()` wins over any `reconcile` in progress.
public actor CoreAudioAppController: AppAudioController {
  /// A live tap and what it was built for.
  private struct Entry {
    let handle: any TapHandle
    let token: Int
    let key: SessionKey
    /// The `restoreAll` generation the tap was created under.
    let generation: Int
    var health: SessionHealth
  }

  private let engine: any TapEngine
  private let clock: AppClock
  private let policy: WatchdogPolicy
  nonisolated let generation = Generation()
  private let changes: AsyncStream<EnvironmentChange>
  nonisolated let killList = KillList()
  private let failureHub = EventHub<AppAudioFailure>()

  private var entries: [String: Entry] = [:]
  /// Latched failures, with the `restoreAll` generation they happened under.
  private var failed: [String: (reason: AppAudioFailure.Reason, generation: Int)] = [:]
  private var lastDesired: (generation: Int, list: [DesiredAppAudio])?
  private var serviceGeneration = 0
  private var watchdog: Task<Void, Never>?
  private var environment: Task<Void, Never>?

  /// Creates the controller for real hardware.
  /// - Parameters:
  ///   - catalog: how processes are read.
  ///   - identity: confirms PID, bundle ID and path before each tap (SPEC 12.9.4).
  ///   - clock: drives the watchdog; tests inject a fake.
  public init(
    catalog: ProcessCatalog, identity: any ProcessIdentityChecking,
    clock: AppClock = ContinuousClock()
  ) {
    self.init(
      engine: CoreAudioTapEngine(catalog: catalog, identity: identity), clock: clock,
      policy: WatchdogPolicy())
  }

  init(engine: any TapEngine, clock: AppClock, policy: WatchdogPolicy) {
    self.engine = engine
    self.clock = clock
    self.policy = policy
    changes = engine.environmentChanges()
  }

  /// Starts listening to environment changes on first use. The stream was created in `init`,
  /// so nothing that happened before is lost.
  private func startEnvironmentWatchIfNeeded() {
    guard environment == nil else { return }
    let changes = changes
    environment = Task { [weak self] in
      for await change in changes {
        guard let self else { return }
        await self.handle(change)
      }
    }
  }

  deinit {
    killList.stopAll()
    watchdog?.cancel()
    environment?.cancel()
  }

  // MARK: AppAudioController

  /// Makes the real audio match `desired`. Idempotent.
  public nonisolated func reconcile(desired: [DesiredAppAudio]) async {
    let issued = generation.current
    await apply(desired, issuedAt: issued)
  }

  /// Destroys every tap now, even while a `reconcile` is in progress, and cancels that work.
  public nonisolated func restoreAll() async {
    let newGeneration = generation.advance()
    killList.stopAll()
    await finishRestore(newGeneration)
  }

  // MARK: Extras for the app and vmctl

  /// Failures, one event per app that lost its tap or could not get one.
  public nonisolated func failures() -> AsyncStream<AppAudioFailure> {
    failureHub.makeStream()
  }

  /// Allows a new attempt for an app that failed (user action, for example after the
  /// permission was granted). Takes effect at the next `reconcile`.
  public func retry(appID: String) {
    failed.removeValue(forKey: appID)
  }

  /// Allows a new attempt for every failed app.
  public func retryAll() {
    failed.removeAll()
  }

  /// The active taps.
  public func diagnostics() -> [TapDiagnostics] {
    entries.values.map { $0.handle.diagnostics }.sorted { $0.appID < $1.appID }
  }

  // MARK: Reconciliation

  private func apply(_ desired: [DesiredAppAudio], issuedAt issued: Int) async {
    guard generation.current == issued else { return }
    startEnvironmentWatchIfNeeded()
    lastDesired = (issued, desired)
    var wanted: [String: DesiredAppAudio] = [:]
    for item in desired { wanted[item.app.id] = item }

    for id in entries.keys where wanted[id] == nil { destroy(id) }
    failed = failed.filter { wanted[$0.key] != nil }

    var seen: Set<String> = []
    for item in desired where seen.insert(item.app.id).inserted {
      guard generation.current == issued else { return }
      await reconcile(wanted[item.app.id] ?? item, issuedAt: issued)
    }
    startWatchdogIfNeeded()
  }

  private func reconcile(_ item: DesiredAppAudio, issuedAt issued: Int) async {
    let id = item.app.id
    if failed[id] != nil { return }
    // A tap from before the last `restoreAll` is already stopped: never reuse it.
    if let old = entries[id], old.generation < issued { destroy(id) }
    guard let device = engine.deviceSignature(uid: item.targetDeviceUID) else {
      destroy(id)
      emit(AppAudioFailure(appID: id, reason: .deviceUnavailable))
      return
    }
    let key = SessionKey(
      pids: item.app.pids.sorted(), deviceUID: item.targetDeviceUID, device: device,
      serviceGeneration: serviceGeneration)
    let gain = Self.effectiveGain(item)
    switch ReconcilePlanner.plan(current: entries[id]?.key, wanted: key) {
    case .none, .destroy:
      destroy(id)
    case .update:
      entries[id]?.handle.setTarget(gain: gain)
    case .create:
      _ = await start(
        item, key: key, gain: gain, initialGain: gain, issuedAt: issued, replacing: nil)
    case .replaceHard:
      destroy(id)
      _ = await start(
        item, key: key, gain: gain, initialGain: gain, issuedAt: issued, replacing: nil)
    case .replaceGracefully:
      let old = entries[id]
      _ = await start(item, key: key, gain: gain, initialGain: 0, issuedAt: issued, replacing: old)
    }
  }

  /// Starts a tap. With `replacing`, the old tap fades out while the new one fades in.
  private func start(
    _ item: DesiredAppAudio, key: SessionKey, gain: Float, initialGain: Float,
    issuedAt issued: Int, replacing old: Entry?
  ) async -> Bool {
    let id = item.app.id
    let processes = engine.confirmedProcesses(for: item.app)
    guard !processes.isEmpty else {
      destroy(id)
      return false
    }
    let request = TapRequest(
      app: item.app, processes: processes,
      device: key.device, initialGain: initialGain, targetGain: gain)
    let generation = generation
    do {
      let handle = try engine.makeSession(
        request, isCancelled: { generation.current != issued })
      let token = killList.add(handle)
      if generation.current != issued {
        handle.stop()
        killList.remove(token)
        return false
      }
      entries[id] = Entry(
        handle: handle, token: token, key: key, generation: issued,
        health: SessionHealth(policy: policy))
      if let old {
        let serviceAtStart = serviceGeneration
        old.handle.setTarget(gain: 0)
        try? await clock.sleep(for: policy.crossfade)
        // If `coreaudiod` restarted during the fade, the old objects are already gone.
        if serviceGeneration == serviceAtStart {
          old.handle.stop()
        } else {
          old.handle.abandon()
        }
        killList.remove(old.token)
      }
      return true
    } catch {
      switch error {
      case .cancelled, .processGone:
        destroy(id)
      case .incompatibleFormat(let mismatch):
        AudioLog.logger.error(
          "tap format incompatible: \(String(describing: mismatch), privacy: .public)")
        fail(id, .incompatibleFormat)
      case .coreAudio(let cause):
        AudioLog.logger.error("tap creation failed: \(cause.description, privacy: .public)")
        fail(id, .creationFailed)
      }
      return false
    }
  }

  private static func effectiveGain(_ item: DesiredAppAudio) -> Float {
    if item.muted { return 0 }
    return item.gain.isNaN ? 1 : min(max(item.gain, 0), 1)
  }

  // MARK: Teardown and failures

  private func destroy(_ id: String) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.handle.stop()
    killList.remove(entry.token)
    cancelWatchdogIfIdle()
  }

  /// After a `coreaudiod` restart: forgets the tap without destroying anything, because the
  /// server lost its objects and the old IDs may now name objects that are not ours (M-2).
  private func forget(_ id: String) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.handle.abandon()
    killList.remove(entry.token)
    cancelWatchdogIfIdle()
  }

  /// The check exists only while taps exist (SPEC 4.6, 12.4): drop the timer with the last tap.
  private func cancelWatchdogIfIdle() {
    guard entries.isEmpty else { return }
    watchdog?.cancel()
    watchdog = nil
  }

  /// Fail open: destroys the tap, remembers the failure (no retry loop) and tells the domain.
  private func fail(_ id: String, _ reason: AppAudioFailure.Reason) {
    AudioLog.logger.error(
      "control failed, tap destroyed: \(String(describing: reason), privacy: .public)")
    destroy(id)
    failed[id] = (reason, generation.current)
    emit(AppAudioFailure(appID: id, reason: reason))
  }

  private func emit(_ failure: AppAudioFailure) {
    failureHub.yield(failure)
  }

  /// Clears the bookkeeping of everything older than `newGeneration`. A `reconcile` issued
  /// after the restore may already have run; its taps are kept.
  func finishRestore(_ newGeneration: Int) {
    for (id, entry) in entries where entry.generation < newGeneration { destroy(id) }
    failed = failed.filter { $0.value.generation >= newGeneration }
    if let last = lastDesired, last.generation < newGeneration { lastDesired = nil }
    cancelWatchdogIfIdle()
  }

  // MARK: Watchdog (only while taps exist)

  private func startWatchdogIfNeeded() {
    guard watchdog == nil, !entries.isEmpty else { return }
    let clock = clock
    let tick = policy.tick
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: tick) } catch { return }
        guard let self else { return }
        if await self.watchdogTick() == false { return }
      }
    }
  }

  /// Returns false when there is nothing left to watch.
  private func watchdogTick() -> Bool {
    for id in entries.keys.sorted() {
      guard var entry = entries[id] else { continue }
      let verdict = entry.health.evaluate(
        frames: entry.handle.framesProcessed,
        sawSignal: entry.handle.consumeSignalFlag(),
        appRunning: engine.isRunningOutput(pids: entry.key.pids),
        fault: entry.handle.hasFault)
      entries[id] = entry
      switch verdict {
      case .healthy: break
      case .stalled: fail(id, .noAudioFrames)
      case .silent: fail(id, .permissionLikelyDenied)
      case .faulted: fail(id, .ioFault)
      }
    }
    if entries.isEmpty {
      watchdog = nil
      return false
    }
    return true
  }

  // MARK: Environment

  private func handle(_ change: EnvironmentChange) async {
    if change == .serviceRestarted {
      serviceGeneration += 1
      for id in Array(entries.keys) { forget(id) }
      failed.removeAll()
    }
    guard let last = lastDesired, last.generation == generation.current
    else { return }
    await apply(last.list, issuedAt: last.generation)
  }
}
