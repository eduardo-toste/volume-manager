import CoreAudio
import Darwin
import Foundation
import VolumeCore

/// How the signal check concludes (pure, testable).
enum AccessDecision {
  /// - Parameters:
  ///   - sawSignal: a non-zero sample arrived during the listening window.
  ///   - stillPlaying: the listened-to processes still report output at the end.
  static func verdict(sawSignal: Bool, stillPlaying: Bool) -> AudioAccessVerdict {
    if sawSignal { return .granted }
    return stillPlaying ? .denied : .indeterminate
  }
}

/// Real `AudioAccessProbe` (SPEC 4.6, 5).
///
/// Evaluation of the M3 QA recommendation: both checks use **tap of process objects** (never a
/// global tap). `probe()` creates, and destroys at once, an unmuted tap of one other audio
/// process; `verify()` listens for ~500 ms to an unmuted tap of the processes that are playing.
/// Unmuted taps never change what the user hears, and nothing is written anywhere: the IOProc
/// only records "was any sample non-zero?" (SPEC 12.9.3).
public struct SystemAudioAccessProbe: AudioAccessProbe {
  private let catalog: ProcessCatalog
  private let clock: AppClock
  private let listenDuration: Duration
  private let candidates: (@Sendable () -> [AudioObjectID])?

  /// Creates the probe. It holds no state.
  public init(
    catalog: ProcessCatalog = ProcessCatalog(), clock: AppClock = ContinuousClock(),
    listenDuration: Duration = .milliseconds(500)
  ) {
    self.catalog = catalog
    self.clock = clock
    self.listenDuration = listenDuration
    candidates = nil
  }

  /// For tests: listens only to the processes `candidates` names, never to the user's apps.
  init(
    catalog: ProcessCatalog, clock: AppClock = ContinuousClock(),
    listenDuration: Duration = .milliseconds(500),
    candidates: @escaping @Sendable () -> [AudioObjectID]
  ) {
    self.catalog = catalog
    self.clock = clock
    self.listenDuration = listenDuration
    self.candidates = candidates
  }

  /// Creates and destroys one unmuted test tap (no aggregate device, no IOProc). This is what
  /// shows the system prompt when the permission is undecided. When no other audio process
  /// exists there is nothing to tap, so no tap is created and the result is `false`.
  public func probe() -> Bool {
    probe(target: testTarget())
  }

  /// The process to test with, chosen from the audio processes other than this one.
  private func testTarget() -> AudioObjectID? {
    let others = catalog.objectIDs().filter { catalog.pid(of: $0) != getpid() }
    return Self.chooseTarget(among: others, isPlaying: { catalog.runningOutput($0) })
  }

  /// The process to test with: one that is playing, else any. `nil` when there is none.
  static func chooseTarget(
    among others: [AudioObjectID], isPlaying: (AudioObjectID) -> Bool
  ) -> AudioObjectID? {
    others.first(where: isPlaying) ?? others.first
  }

  /// Creates and destroys the test tap on `target`; `false` without creating anything when
  /// `target` is `nil`. Never uses a global tap.
  func probe(target: AudioObjectID?) -> Bool {
    guard let target else { return false }
    AudioLog.logger.info("access check: test tap created and destroyed")
    let description = CATapDescription(monoMixdownOfProcesses: [target])
    description.name = "Volume access check"
    description.isPrivate = true
    description.muteBehavior = .unmuted
    let pipeline = TapPipeline()
    do {
      _ = try pipeline.createTap(description)
    } catch {
      return false
    }
    pipeline.teardown()
    return true
  }

  /// Creating the tap itself failed while every process it named still exists: refused. A
  /// process that ended in between, or any later step: cannot conclude. Decided by the
  /// error's stage, never by its text.
  static func verdictAfterFailure(_ error: AudioError, targetsExist: Bool) -> AudioAccessVerdict {
    error.stage == .createTap && targetsExist ? .denied : .indeterminate
  }

  /// True while every one of `objects` is still an audio process.
  private func exist(_ objects: [AudioObjectID]) -> Bool {
    objects.allSatisfy { catalog.pid(of: $0) != nil }
  }

  /// Listens to the processes that are playing; see `AudioAccessProbe.verify(idleTargetAllowed:)`. When nothing is
  /// playing it listens the same way to any other audio process: the tap, the aggregate and the
  /// IO are what makes the system show its permission prompt, a bare tap does not. Without a
  /// signal that is `.indeterminate` (nothing was playing).
  public func verify(idleTargetAllowed: Bool) async -> AudioAccessVerdict {
    let playing = Array((candidates?() ?? catalog.playingObjectIDs(excluding: getpid())).prefix(16))
    if !playing.isEmpty { return await listen(to: playing) }
    // The test seam never reaches the user's own processes.
    guard candidates == nil, let target = testTarget() else { return .indeterminate }
    // Only the user may start listening to an idle process (that is what shows the prompt).
    // Automatic checks only create and destroy a bare tap, as before.
    guard idleTargetAllowed else {
      return probe(target: target) || !exist([target]) ? .indeterminate : .denied
    }
    return await listen(to: [target])
  }

  /// Creates an unmuted private tap on `playing`, an aggregate with auto-start and the signal
  /// IO, listens for `listenDuration` and destroys everything, on every path.
  private func listen(to playing: [AudioObjectID]) async -> AudioAccessVerdict {
    AudioLog.logger.info("access check: listening tap, aggregate and IO started")
    let pipeline = TapPipeline()
    let state = SignalProbeState()
    do {
      let description = CATapDescription(monoMixdownOfProcesses: playing)
      description.name = "Volume access check"
      description.isPrivate = true
      description.muteBehavior = .unmuted
      _ = try pipeline.createTap(description)
      _ = try pipeline.createAggregate([
        kAudioAggregateDeviceNameKey: "Volume access check",
        kAudioAggregateDeviceUIDKey: DeviceCatalog.aggregateUIDPrefix + UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceTapListKey: [
          [kAudioSubTapUIDKey: description.uuid.uuidString]
        ],
      ])
      try pipeline.startIO(
        proc: signalProbeIOProc, client: Unmanaged.passUnretained(state).toOpaque())
    } catch {
      pipeline.teardown(keeping: state)
      // Creating the tap itself failed: refused. Anything later: cannot conclude.
      return Self.verdictAfterFailure(error, targetsExist: exist(playing))
    }
    try? await clock.sleep(for: listenDuration)
    pipeline.teardown(keeping: state)
    // Cut short (the task was cancelled) without sound: nothing was really listened to, so it
    // proves nothing (S53R-B1). Real sound still proves the permission.
    if Task.isCancelled, !state.sawSignal { return .indeterminate }
    let stillPlaying = playing.contains { catalog.runningOutput($0) }
    return AccessDecision.verdict(sawSignal: state.sawSignal, stillPlaying: stillPlaying)
  }
}
