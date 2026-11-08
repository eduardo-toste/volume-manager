import CoreAudio
import Foundation
import VolumeCore

/// The IOProc: hands the buffers to `RealtimeTapState.render`. No allocation, locks, logging,
/// async or reference counting: the state is reached through an unretained pointer that the
/// session keeps alive until the IOProc is destroyed.
private let tapIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, client in
  guard let client else { return noErr }
  Unmanaged<RealtimeTapState>.fromOpaque(client)._withUnsafeGuaranteedRef { state in
    state.render(input: input, output: output)
  }
  return noErr
}

/// One running tap: process tap + private aggregate device + IOProc, destroyed in order when
/// stopped or released.
final class CoreAudioTapSession: TapHandle {
  private let state: RealtimeTapState
  private let pipeline: TapPipeline
  private let listeners: [PropertyListener]
  private let info: TapDiagnostics

  private init(
    state: RealtimeTapState, pipeline: TapPipeline, listeners: [PropertyListener],
    info: TapDiagnostics
  ) {
    self.state = state
    self.pipeline = pipeline
    self.listeners = listeners
    self.info = info
  }

  var framesProcessed: UInt64 { state.framesProcessed }
  func consumeSignalFlag() -> Bool { state.consumeSignalFlag() }
  var hasFault: Bool { state.hasFault }
  func setTarget(gain: Float) { state.setTarget(gain) }

  /// Formats are fixed at creation; the counters are read live.
  var diagnostics: TapDiagnostics {
    TapDiagnostics(
      appID: info.appID, pids: info.pids, deviceUID: info.deviceUID,
      framesProcessed: state.framesProcessed, hasSeenSignal: state.hasEverSeenSignal,
      tapFormat: info.tapFormat, outputFormat: info.outputFormat,
      isFormatMonitored: info.isFormatMonitored)
  }

  func stop() {
    for listener in listeners { listener.cancel() }
    pipeline.teardown()
  }

  /// Forgets the Core Audio objects without destroying them (SPEC 4.6, finding M-2): after a
  /// `coreaudiod` restart their IDs are meaningless and may belong to someone else's objects,
  /// so no destroy or stop is sent for them. Cancelling the listeners still passes the old
  /// device ID to `AudioObjectRemovePropertyListenerBlock`; that is harmless because it only
  /// removes this process's own listener blocks.
  /// The realtime state is deliberately kept alive forever (a few bytes) because the IOProc
  /// holds an unretained pointer to it and we cannot prove the client side stopped calling it.
  func abandon() {
    for listener in listeners { listener.cancel() }
    pipeline.abandon()
    _ = Unmanaged.passRetained(state)
  }

  deinit { stop() }

  /// Builds and starts a tap. On any failure everything created so far is destroyed.
  static func start(
    _ request: TapRequest, queue: DispatchQueue,
    notify: @escaping @Sendable (EnvironmentChange) -> Void,
    isCancelled: @Sendable () -> Bool
  ) throws(TapError) -> CoreAudioTapSession {
    let output = request.device.layout
    let objectIDs = request.objectIDs
    do {
      try FormatPolicy.validateOutput(output)
    } catch {
      throw .incompatibleFormat(error)
    }
    guard let channels = FormatPolicy.tapChannels(forOutputChannels: output.channels) else {
      throw .incompatibleFormat(.unsupportedChannelCount(output.channels))
    }
    if isCancelled() { throw .cancelled }

    let pipeline = TapPipeline()
    let state = RealtimeTapState(
      initialGain: request.initialGain, target: request.targetGain,
      step: GainKernel.rampStep(sampleRate: output.sampleRate))
    let tapLayout: StreamLayout
    do {
      let description =
        channels == 1
        ? CATapDescription(monoMixdownOfProcesses: objectIDs)
        : CATapDescription(stereoMixdownOfProcesses: objectIDs)
      description.name = "Volume tap"
      description.isPrivate = true
      description.muteBehavior = .mutedWhenTapped
      let tapID = try pipeline.createTap(description)
      let format = try AudioProperty.get(
        tapID, AudioProperty.address(kAudioTapPropertyFormat),
        initial: AudioStreamBasicDescription())
      tapLayout = StreamLayout(format)
      if isCancelled() { throw TapError.cancelled }

      let aggregateID = try pipeline.createAggregate(
        aggregateDictionary(
          tapUUID: description.uuid.uuidString, outputUID: request.device.rawUID,
          sampleRatesDiffer: tapLayout.sampleRate != output.sampleRate))
      let inputShape = try AudioProperty.bufferShape(
        aggregateID, scope: kAudioObjectPropertyScopeInput)
      let outputShape = try AudioProperty.bufferShape(
        aggregateID, scope: kAudioObjectPropertyScopeOutput)
      let offset: Int
      do {
        offset = try FormatPolicy.validate(
          tap: tapLayout, output: output, inputShape: inputShape, outputShape: outputShape)
      } catch {
        throw TapError.incompatibleFormat(error)
      }
      if let rate = try? AudioProperty.get(
        aggregateID, AudioProperty.address(kAudioDevicePropertyNominalSampleRate),
        initial: Float64(0))
      {
        state.setStep(GainKernel.rampStep(sampleRate: rate))
      }
      state.setInputOffset(offset)
      if isCancelled() { throw TapError.cancelled }
      try pipeline.startIO(
        proc: tapIOProc, client: Unmanaged.passUnretained(state).toOpaque())
    } catch let error as TapError {
      // The IOProc holds an unretained pointer to `state`: keep it alive until teardown.
      withExtendedLifetime(state) { pipeline.teardown() }
      throw error
    } catch {
      withExtendedLifetime(state) { pipeline.teardown() }
      throw .coreAudio(
        (error as? AudioError) ?? AudioError.unsupported("unexpected error creating tap"))
    }

    let uid = request.device.uid
    let addresses = [
      AudioProperty.address(kAudioDevicePropertyNominalSampleRate),
      AudioProperty.address(
        kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeOutput),
    ]
    var listener: PropertyListener?
    do {
      listener = try PropertyListener(
        object: request.device.id, addresses: addresses, queue: queue,
        handler: { notify(.deviceFormatChanged(uid: uid)) })
    } catch {
      // Not fatal, but format changes will not be noticed between reconciles: the session is
      // marked as not monitored and every `reconcile` re-reads the device format anyway.
      AudioLog.logger.error(
        "device format listener failed: \(error.description, privacy: .public)")
    }
    let info = TapDiagnostics(
      appID: request.app.id, pids: request.pids, deviceUID: uid, framesProcessed: 0,
      hasSeenSignal: false, tapFormat: tapLayout.summary, outputFormat: output.summary,
      isFormatMonitored: listener != nil)
    return CoreAudioTapSession(
      state: state, pipeline: pipeline, listeners: listener.map { [$0] } ?? [], info: info)
  }

  private static func aggregateDictionary(
    tapUUID: String, outputUID: String, sampleRatesDiffer: Bool
  ) -> [String: Any] {
    var tap: [String: Any] = [
      kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true,
    ]
    if sampleRatesDiffer {
      tap[kAudioSubTapDriftCompensationQualityKey] = kAudioAggregateDriftCompensationMaxQuality
    }
    return [
      kAudioAggregateDeviceNameKey: "Volume aggregate",
      kAudioAggregateDeviceUIDKey: DeviceCatalog.aggregateUIDPrefix + UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
      kAudioAggregateDeviceTapListKey: [tap],
    ]
  }
}
