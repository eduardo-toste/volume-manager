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
  /// shows the system prompt when the permission is undecided.
  public func probe() -> Bool {
    let others = catalog.objectIDs().filter { catalog.pid(of: $0) != getpid() }
    let description: CATapDescription
    if let target = others.first(where: { catalog.runningOutput($0) }) ?? others.first {
      description = CATapDescription(monoMixdownOfProcesses: [target])
    } else {
      // No other audio process exists, so there is no single process to tap.
      description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    }
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

  /// Listens to the processes that are playing; see `AudioAccessProbe.verify()`.
  public func verify() async -> AudioAccessVerdict {
    let playing = Array((candidates?() ?? catalog.playingObjectIDs(excluding: getpid())).prefix(16))
    guard !playing.isEmpty else { return probe() ? .indeterminate : .denied }

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
      withExtendedLifetime(state) { pipeline.teardown() }
      // Creating the tap itself failed: refused. Anything later: cannot conclude.
      return error.context.hasPrefix("create process tap") ? .denied : .indeterminate
    }
    try? await clock.sleep(for: listenDuration)
    withExtendedLifetime(state) { pipeline.teardown() }
    let stillPlaying = playing.contains { catalog.runningOutput($0) }
    return AccessDecision.verdict(sawSignal: state.sawSignal, stillPlaying: stillPlaying)
  }
}
