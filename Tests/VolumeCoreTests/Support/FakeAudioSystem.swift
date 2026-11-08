import Synchronization

@testable import VolumeCore

/// Emits processes and devices on command and records the system-level calls it receives.
final class FakeAudioSystem: AudioSystem, Sendable {
  enum Call: Sendable, Hashable {
    case masterVolume(Double)
    case masterMuted(Bool)
    case defaultOutput(String)
    case refresh
  }

  private struct State {
    var snapshot = AudioSystemSnapshot()
    var calls: [Call] = []
    var continuations: [AsyncStream<AudioSystemEvent>.Continuation] = []
  }

  private let state = Mutex(State())

  var calls: [Call] { state.withLock { $0.calls } }

  func setSnapshot(_ snapshot: AudioSystemSnapshot) {
    state.withLock { $0.snapshot = snapshot }
  }

  func emit(_ event: AudioSystemEvent) {
    let all = state.withLock { $0.continuations }
    for continuation in all { continuation.yield(event) }
  }

  func finish() {
    let all = state.withLock { $0.continuations }
    for continuation in all { continuation.finish() }
  }

  var subscriberCount: Int { state.withLock { $0.continuations.count } }

  func events() -> AsyncStream<AudioSystemEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: AudioSystemEvent.self)
    state.withLock { $0.continuations.append(continuation) }
    return stream
  }

  func currentState() async -> AudioSystemSnapshot { state.withLock { $0.snapshot } }

  func refresh() async { state.withLock { $0.calls.append(.refresh) } }

  func setMasterVolume(_ volume: Double) async {
    state.withLock { $0.calls.append(.masterVolume(volume)) }
  }

  func setMasterMuted(_ muted: Bool) async {
    state.withLock { $0.calls.append(.masterMuted(muted)) }
  }

  func setDefaultOutput(uid: String) async {
    state.withLock { $0.calls.append(.defaultOutput(uid)) }
  }
}
