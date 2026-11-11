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
    var refreshPublishes = false
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

  /// True: `refresh()` also emits the snapshot's processes, as the real system does when it
  /// re-reads them (the notification path is then not needed).
  var refreshPublishes: Bool {
    get { state.withLock { $0.refreshPublishes } }
    set { state.withLock { $0.refreshPublishes = newValue } }
  }

  func refresh() async {
    let publish = state.withLock {
      $0.calls.append(.refresh)
      return $0.refreshPublishes
    }
    if publish { emit(.processes(state.withLock { $0.snapshot.processes })) }
  }

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
