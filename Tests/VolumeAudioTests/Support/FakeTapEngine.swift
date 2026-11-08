import CoreAudio
import Dispatch
import Synchronization
import VolumeCore

@testable import VolumeAudio

/// A tap that records what the controller does to it.
final class FakeTapHandle: TapHandle {
  private struct State {
    var frames: UInt64 = 0
    var signal = false
    var fault = false
    var targets: [Float] = []
    var stopped = false
  }

  let request: TapRequest
  private let state = Mutex(State())

  init(request: TapRequest) {
    self.request = request
    state.withLock { $0.targets = [request.targetGain] }
  }

  var framesProcessed: UInt64 { state.withLock { $0.frames } }
  func consumeSignalFlag() -> Bool {
    state.withLock { s in
      defer { s.signal = false }
      return s.signal
    }
  }
  var hasFault: Bool { state.withLock { $0.fault } }
  func setTarget(gain: Float) { state.withLock { $0.targets.append(gain) } }
  func stop() { state.withLock { $0.stopped = true } }
  var diagnostics: TapDiagnostics {
    TapDiagnostics(
      appID: request.app.id, pids: request.pids, deviceUID: request.device.uid,
      framesProcessed: framesProcessed, hasSeenSignal: false, tapFormat: "fake",
      outputFormat: "fake")
  }

  // Test controls
  var targets: [Float] { state.withLock { $0.targets } }
  var isStopped: Bool { state.withLock { $0.stopped } }
  func deliver(frames: UInt64, signal: Bool) {
    state.withLock {
      $0.frames += frames
      if signal { $0.signal = true }
    }
  }
  func raiseFault() { state.withLock { $0.fault = true } }
}

/// A scripted `TapEngine`.
final class FakeTapEngine: TapEngine {
  private struct State {
    var devices: [String: DeviceSignature] = [:]
    var running = true
    var created: [FakeTapHandle] = []
    var failure: TapError?
    var confirm: (@Sendable (ControlledApp) -> [Int32])?
    var entered = 0
  }

  private let state = Mutex(State())
  private let hub = EventHub<EnvironmentChange>()
  /// When set, `makeSession` blocks here (after recording that it entered).
  private let gate = Mutex<DispatchSemaphore?>(nil)

  func setDevice(_ uid: String, rate: Double = 48_000, channels: UInt32 = 2, id: UInt32 = 1) {
    state.withLock {
      $0.devices[uid] = DeviceSignature(
        id: id, uid: uid, layout: StreamLayout(sampleRate: rate, channels: channels))
    }
  }
  func removeDevice(_ uid: String) { state.withLock { _ = $0.devices.removeValue(forKey: uid) } }
  func setRunning(_ value: Bool) { state.withLock { $0.running = value } }
  func failNext(_ error: TapError?) { state.withLock { $0.failure = error } }
  func setConfirm(_ closure: @escaping @Sendable (ControlledApp) -> [Int32]) {
    state.withLock { $0.confirm = closure }
  }
  func blockCreation(_ semaphore: DispatchSemaphore?) { gate.withLock { $0 = semaphore } }
  func emit(_ change: EnvironmentChange) { hub.yield(change) }

  var created: [FakeTapHandle] { state.withLock { $0.created } }
  var live: [FakeTapHandle] { created.filter { !$0.isStopped } }
  var enteredCount: Int { state.withLock { $0.entered } }

  func deviceSignature(uid: String) -> DeviceSignature? { state.withLock { $0.devices[uid] } }
  func confirmedPIDs(for app: ControlledApp) -> [Int32] {
    let closure = state.withLock { $0.confirm }
    return closure?(app) ?? app.pids
  }
  func isRunningOutput(pids: [Int32]) -> Bool { state.withLock { $0.running } }
  func environmentChanges() -> AsyncStream<EnvironmentChange> { hub.makeStream() }

  func makeSession(_ request: TapRequest, isCancelled: @Sendable () -> Bool) throws(TapError)
    -> any TapHandle
  {
    state.withLock { $0.entered += 1 }
    gate.withLock { $0 }?.wait()
    if isCancelled() { throw .cancelled }
    if let failure = state.withLock({ $0.failure }) { throw failure }
    let handle = FakeTapHandle(request: request)
    state.withLock { $0.created.append(handle) }
    return handle
  }
}
