import Synchronization

/// Every live tap, reachable without going through the controller's actor. `restoreAll` uses
/// it to destroy taps at once even while a `reconcile` is busy inside Core Audio.
final class KillList: Sendable {
  private struct State {
    var next = 0
    var handles: [Int: any TapHandle] = [:]
  }

  private let state = Mutex(State())

  /// Registers a tap; returns the token to remove it with.
  func add(_ handle: any TapHandle) -> Int {
    state.withLock { state in
      state.next += 1
      state.handles[state.next] = handle
      return state.next
    }
  }

  func remove(_ token: Int) {
    state.withLock { _ = $0.handles.removeValue(forKey: token) }
  }

  /// Stops and forgets every tap. Stopping happens outside the lock.
  func stopAll() {
    let all = state.withLock { state -> [any TapHandle] in
      let values = Array(state.handles.values)
      state.handles.removeAll()
      return values
    }
    for handle in all { handle.stop() }
  }

  var count: Int { state.withLock { $0.handles.count } }
}
